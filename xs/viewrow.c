#include "perl-couchbase.h"
#include <libcouchbase/views.h>
#include <libcouchbase/n1ql.h>

static void
rowreq_init_common(PLCB_t *parent, AV *req)
{
    av_fill(req, PLCB_VHIDX_MAX);
    av_store(req, PLCB_VHIDX_ROWBUF, newRV_noinc((SV *)newAV()));
    av_store(req, PLCB_VHIDX_RAWROWS, newRV_noinc((SV *)newAV()));
    av_store(req, PLCB_VHIDX_PARENT, newRV_inc(parent->selfobj));
}

static PLCB_t *
parent_from_req(AV *req)
{
    SV **pp = av_fetch(req, PLCB_VHIDX_PARENT, 0);
    return NUM2PTR(PLCB_t*,SvUV(SvRV(*pp)));
}

/* Handles the row, adding it into the internal structure */
static void
invoke_row(AV *req, SV *reqrv, SV *rowsrv)
{
    SV *meth;

    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);

    /* First arg */
    XPUSHs(reqrv);

    meth = *av_fetch(req, PLCB_VHIDX_PRIVCB, 0);
    if (rowsrv) {
        XPUSHs(rowsrv);
    }

    PUTBACK;
    call_sv(meth, G_DISCARD|G_EVAL);
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        warn("Got error in %s", SvPV_nolen(ERRSV));
    }

    if (rowsrv) {
        av_clear((AV *)SvRV(rowsrv));
    }

    FREETMPS;
    LEAVE;
}

/* Wraps the buf:length pair as an SV */
static SV *
sv_from_rowdata(const char *s, size_t n)
{
    if (s && n) {
        SV *ret = newSVpvn(s, n);
        SvUTF8_on(ret);
        return ret;
    } else {
        return SvREFCNT_inc(&PL_sv_undef);
    }
}

static void
viewrow_callback(lcb_t obj, int ct, const lcb_RESPVIEWQUERY *resp)
{
    SV *req_rv = resp->cookie;
    AV *req = (AV *)SvRV(req_rv);

    SV *rawrows_rv = *av_fetch(req, PLCB_VHIDX_RAWROWS, 0);
    AV *rawrows = (AV *)SvRV(rawrows_rv);

    PLCB_t *plobj = parent_from_req(req);

    plcb_evloop_wait_unref(plobj);
    if (resp->rflags & LCB_RESP_F_FINAL) {

        /* Flush any remaining rows.. */
        invoke_row(req, req_rv, rawrows_rv);

        av_store(req, PLCB_VHIDX_ISDONE, SvREFCNT_inc(&PL_sv_yes));
        av_store(req, PLCB_VHIDX_RC, newSViv(resp->rc));
        av_store(req, PLCB_VHIDX_META, sv_from_rowdata(resp->value, resp->nvalue));

        if (resp->htresp) {
            av_store(req, PLCB_VHIDX_HTCODE, newSViv(resp->htresp->htstatus));
        }
        invoke_row(req, req_rv, NULL);
        SvREFCNT_dec(req_rv);
    } else {
        HV *rowdata = newHV();
        /* Key, Value, Doc ID, Geo, Doc */
        hv_stores(rowdata, "key", sv_from_rowdata(resp->key, resp->nkey));
        hv_stores(rowdata, "value", sv_from_rowdata(resp->value, resp->nvalue));
        hv_stores(rowdata, "geometry", sv_from_rowdata(resp->geometry, resp->ngeometry));
        hv_stores(rowdata, "id", sv_from_rowdata(resp->docid, resp->ndocid));

        if (resp->docresp && resp->docresp->rc == LCB_SUCCESS) {
            hv_stores(rowdata, "__doc__",
                newSVpvn(resp->docresp->value, resp->docresp->nvalue));
        }
        av_push(rawrows, newRV_noinc((SV*)rowdata));
        if (av_len(rawrows) >= 20) {
            invoke_row(req, req_rv, rawrows_rv);
        }
    }
}

SV *
PLCB__viewhandle_new(PLCB_t *parent,
    const char *ddoc, const char *view, const char *options, int flags)
{
    AV *req = NULL;
    SV *blessed, *cbrv;
    lcb_CMDVIEWQUERY cmd = { 0 };
    lcb_error_t rc;

    req = newAV();
    rowreq_init_common(parent, req);
    blessed = newRV_noinc((SV*)req);
    sv_bless(blessed, parent->view_stash);

    cbrv = newSVsv(blessed);

    lcb_view_query_initcmd(&cmd, ddoc, view, options, viewrow_callback);
    cmd.cmdflags = flags; /* Trust lcb on this */

    rc = lcb_view_query(parent->instance, cbrv, &cmd);

    if (rc != LCB_SUCCESS) {
        SvREFCNT_dec(blessed);
        SvREFCNT_dec(cbrv);
        die("Couldn't issue view query: (0x%x): %s", rc, lcb_strerror(NULL, rc));
    }
    return blessed;
}

void
PLCB__viewhandle_fetch(SV *pp)
{
    AV *req = (AV *)SvRV(pp);
    PLCB_t *parent = parent_from_req(req);
    lcb_wait(parent->instance);
}
