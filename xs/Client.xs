#include "perl-couchbase.h"
#include "plcb-util.h"
#include "plcb-commands.h"

static int PLCB_connect(SV* self);

static inline void
wait_for_single_response(PLCB_t *object)
{
    object->npending++;
    plcb_evloop_start(object);
}


void plcb_cleanup(PLCB_t *object)
{
    if(object->instance) {
        lcb_destroy(object->instance);
        object->instance = NULL;
    }
    if(object->errors) {
        SvREFCNT_dec(object->errors);
        object->errors = NULL;
    }
#define _free_cv(fld) \
    if(object->fld) { \
        SvREFCNT_dec(object->fld); object->fld = NULL; \
}
    _free_cv(cv_compress); _free_cv(cv_decompress);
    _free_cv(cv_serialize); _free_cv(cv_deserialize);
#undef _free_cv
}

void plcb_errstack_push(PLCB_t *object, lcb_error_t err,
                        const char *errinfo)
{
    lcb_t instance;
    SV *errsvs[2];

    instance = object->instance;
    if(!errinfo) {
        errinfo = lcb_strerror(instance, err);
    }
    errsvs[0] = newSViv(err);
    errsvs[1] = newSVpv(errinfo, 0);
    av_push(object->errors,
            newRV_noinc( (SV*)av_make(2, errsvs)));
}

/*Construct a new libcouchbase object*/
SV *PLCB_construct(const char *pkg, AV *options)
{
    lcb_t instance;
    lcb_error_t err;
    struct lcb_io_opt_st *io_ops = NULL;
    struct lcb_create_io_ops_st io_options = { 0 };
    struct lcb_create_st cr_opts = { 0 };
    SV *blessed_obj;
    PLCB_t *object;

    char *host = NULL, *username = NULL, *password = NULL, *bucket = NULL;

    plcb_ctor_cbc_opts(options,
                         &host, &username, &password, &bucket);

    io_options.v.v0.type = LCB_IO_OPS_DEFAULT;
    err = lcb_create_io_ops(&io_ops, &io_options);

    if(io_ops == NULL && err != LCB_SUCCESS) {
        die("Couldn't create new IO operations: %d", err);
    }


    cr_opts.v.v0.bucket = bucket;
    cr_opts.v.v0.host = host;
    cr_opts.v.v0.io = io_ops;
    cr_opts.v.v0.user = username;
    cr_opts.v.v0.passwd = password;

    lcb_create(&instance, &cr_opts);

    if(!instance) {
        die("Failed to create instance");
    }

    Newxz(object, 1, PLCB_t);

    object->io_ops = io_ops;
    plcb_ctor_conversion_opts(object, options);
    plcb_ctor_init_common(object, instance, options);

    lcb_set_cookie(instance, object);

    plcb_callbacks_setup(object);

    blessed_obj = newSV(0);
    sv_setiv(newSVrv(blessed_obj, "Couchbase::Client"), PTR2IV(object));

    if( (object->my_flags & PLCBf_NO_CONNECT) == 0) {
        PLCB_connect(blessed_obj);
    }

    return blessed_obj;
}


#define mk_instance_vars(sv, inst_name, obj_name) \
    if(!SvROK(sv)) { die("self must be a reference"); } \
    obj_name = NUM2PTR(PLCB_t*, SvIV(SvRV(sv))); \
    if(!obj_name) { die("tried to access de-initialized PLCB_t"); } \
    inst_name = obj_name->instance;

#define bless_return(object, rv, av) \
    return plcb_ret_blessed_rv(object, av);


static int
PLCB_connect(SV *self)
{
    lcb_t instance;
    lcb_error_t err;
    PLCB_t *object;

    mk_instance_vars(self, instance, object);

    av_clear(object->errors);

    if(object->connected) {
        warn("Already connected");
        return 1;
    } else {
        if( (err = lcb_connect(instance)) == LCB_SUCCESS) {
            lcb_wait(instance);
            if(av_len(object->errors) > -1) {
                return 0;
            }
            object->connected = 1;
            return 1;
        } else {
            plcb_errstack_push(object, err, NULL);
        }
    }
    return 0;
}


#define _sync_return_single(object, err, syncp) \
    if(err != LCB_SUCCESS ) { \
        plcb_ret_set_err(object, (syncp)->ret, err); \
    } else { \
        wait_for_single_response(object); \
    } \
    return plcb_ret_blessed_rv(object, (syncp)->ret);

#define _sync_initialize_single(object, syncp); \
    syncp = &object->sync; \
    syncp->parent = object; \
    syncp->ret = newAV();

static SV *PLCB_set_common(SV *self,
    SV *key, SV *value,
    int cmd,
    int exp_offset, uint64_t cas)
{
    lcb_t instance;
    PLCB_t *object;
    lcb_error_t err;
    lcb_storage_t storop;
    plcb_conversion_spec_t conversion_spec = PLCB_CONVERT_SPEC_NONE;

    STRLEN klen = 0, vlen = 0;
    char *skey, *sval;
    PLCB_sync_t *syncp;
    time_t exp;
    uint32_t store_flags = 0;

    mk_instance_vars(self, instance, object);

    plcb_get_str_or_die(key, skey, klen, "Key");
    plcb_get_str_or_die(value, sval, vlen, "Value");

    storop = plcb_command_to_storop(cmd);

    /*Clear existing error status first*/
    av_clear(object->errors);

    _sync_initialize_single(object, syncp);

    PLCB_UEXP2EXP(exp, exp_offset, 0);

    if ((cmd & PLCB_COMMAND_EXTRA_MASK) & PLCB_COMMANDf_COUCH) {
        conversion_spec = PLCB_CONVERT_SPEC_JSON;
    }

    plcb_convert_storage(object, &value, &vlen, &store_flags,
                         conversion_spec);

    err = libcouchbase_store(instance, syncp, storop,
        skey, klen, SvPVX(value), vlen, store_flags, exp, cas);
    plcb_convert_storage_free(object, value, store_flags);

    _sync_return_single(object, err, syncp);
}

static SV *PLCB_arithmetic_common(SV *self,
    SV *key, int64_t delta,
    int do_create, uint64_t initial,
    int exp_offset)
{
    PLCB_t *object;
    lcb_t instance;

    char *skey;
    STRLEN nkey;

    PLCB_sync_t *syncp;
    time_t exp;
    lcb_error_t err;

    mk_instance_vars(self, instance, object);
    PLCB_UEXP2EXP(exp, exp_offset, 0);

    plcb_get_str_or_die(key, skey, nkey, "Key");

    _sync_initialize_single(object, syncp);

    err = libcouchbase_arithmetic(
        instance, syncp, skey, nkey, delta,
        exp, do_create, initial
    );

    _sync_return_single(object, err, syncp);
}

static SV *PLCB_get_common(SV *self, SV *key, int exp_offset)
{
    lcb_t instance;
    PLCB_t *object;
    PLCB_sync_t *syncp;
    lcb_error_t err;
    STRLEN klen;
    char *skey;

    time_t exp;
    time_t *exp_arg;

    mk_instance_vars(self, instance, object);
    plcb_get_str_or_die(key, skey, klen, "Key");
    _sync_initialize_single(object, syncp);

    av_clear(object->errors);
    PLCB_UEXP2EXP(exp, exp_offset, 0);
    exp_arg = (exp) ? &exp : NULL;

    err = libcouchbase_mget(instance, syncp, 1,
                            (const void * const*)&skey, &klen,
                            exp_arg);

    _sync_return_single(object, err, syncp);
}

#define set_plst_get_offset(exp_idx, exp_var, diemsg) \
    if(items == (exp_idx - 1)) { \
        exp_var = 0; \
     } else if(items == exp_idx) { \
        if(!SvIOK(ST(exp_idx-1))) { \
            sv_dump(ST(exp_idx-1)); \
            die("Expected numeric argument"); \
        } \
        exp_var = SvIV(ST((exp_idx-1))); \
    } else { \
        die(diemsg); \
    }

/*variable length ->get and ->cas are in the XS section*/


SV *PLCB_get(SV *self, SV *key)
{
    return PLCB_get_common(self, key, 0);
}

SV *PLCB_touch(SV *self, SV *key, UV exp_offset)
{
    return PLCB_get_common(self, key, exp_offset);
}

SV *PLCB_remove(SV *self, SV *key, uint64_t cas)
{
    lcb_t instance;
    PLCB_t *object;
    lcb_error_t err;

    char *skey;
    STRLEN key_len;
    PLCB_sync_t *syncp;

    mk_instance_vars(self, instance, object);

    plcb_get_str_or_die(key, skey, key_len, "Key");
    av_clear(object->errors);

    _sync_initialize_single(object, syncp);

    err = libcouchbase_remove(instance, syncp, skey, key_len, cas);
    _sync_return_single(object, err, syncp);
}

SV *PLCB_stats(SV *self, AV *stats)
{
    lcb_t instance;
    PLCB_t *object;
    char *skey;
    STRLEN nkey;
    int curidx;
    lcb_error_t err;

    SV *ret_hvref;
    SV **tmpsv;

    lcb_server_stats_cmd_t cmd = { 0 };
    const lcb_server_stats_cmd_t *cmdp = &cmd;

    mk_instance_vars(self, instance, object);
    if(object->stats_hv) {
        die("Hrrm.. stats_hv should be NULL");
    }

    av_clear(object->errors);
    object->stats_hv = newHV();
    ret_hvref = newRV_noinc((SV*)object->stats_hv);

    if(stats == NULL || (curidx = av_len(stats)) == -1) {
        skey = NULL;
        nkey = 0;
        curidx = -1;
        err = lcb_server_stats(instance, NULL, 1, &cmdp);
        if(err != LCB_SUCCESS) {
            SvREFCNT_dec(ret_hvref);
            ret_hvref = &PL_sv_undef;
        }

        wait_for_single_response(object);

    } else {
        for(; curidx >= 0; curidx--) {
            tmpsv = av_fetch(stats, curidx, 0);
            if(tmpsv == NULL
               || SvTYPE(*tmpsv) == SVt_NULL
               || (!SvPOK(*tmpsv))) {
                continue;
            }
            skey = SvPV(*tmpsv, nkey);
            cmd.v.v0.name = skey;
            cmd.v.v0.nname = nkey;
            err = lcb_server_stats(instance, NULL, 1, &cmdp);
            if(err == LCB_SUCCESS) {
                wait_for_single_response(object);
            }
        }
    }

    object->stats_hv = NULL;
    return ret_hvref;
}


SV *PLCB_observe(SV *self, SV *key, uint64_t cas)
{
    lcb_t instance;
    PLCB_t *object;
    lcb_error_t err;
    char *skey;
    STRLEN key_len;

    PLCB_obs_t obs;

    lcb_observe_cmd_t cmd = { 0 };
    const lcb_observe_cmd_t *cmdp = &cmd;


    mk_instance_vars(self, instance, object);

    memset(&obs, 0, sizeof(obs));
    obs.sync.parent = object;

    plcb_get_str_or_die(key, skey, key_len, "CAS");
    obs.sync.ret = newAV();
    av_store(obs.sync.ret, PLCB_RETIDX_VALUE,
        newRV_noinc((SV*)newHV()));

    cmd.v.v0.key = skey;
    cmd.v.v0.nkey = key_len;

    obs.orig_cas = cas;

    err = lcb_observe(instance, &obs, 1, &cmdp);
    _sync_return_single(object, err, &(obs.sync));
}

static SV*
return_empty(SV *self, int error, const char *errmsg)
{
    lcb_t instance;
    PLCB_t *object;
    AV *ret_av;

    mk_instance_vars(self, instance, object);
    ret_av = newAV();
    av_store(ret_av, PLCB_RETIDX_ERRNUM, newSViv(error));
    av_store(ret_av, PLCB_RETIDX_ERRSTR, newSVpvf(
        "Couchbase::Client usage error: %s", errmsg));
    plcb_ret_blessed_rv(object, ret_av);
    return &PL_sv_undef;
}

/*used for settings accessors*/
enum {
    SETTINGS_ALIAS_BASE,
    SETTINGS_ALIAS_COMPRESS,
    SETTINGS_ALIAS_COMPRESS_COMPAT,
    SETTINGS_ALIAS_SERIALIZE,
    SETTINGS_ALIAS_CONVERT,
    SETTINGS_ALIAS_DECONVERT,
    SETTINGS_ALIAS_COMP_THRESHOLD,
    SETTINGS_ALIAS_DEREF_RVPV
};



MODULE = Couchbase::Client PACKAGE = Couchbase::Client    PREFIX = PLCB_

PROTOTYPES: DISABLE

SV *
PLCB_construct(pkg, options)
    const char *pkg
    AV *options

void
PLCB_DESTROY(self)
    SV *self

    CODE:
    PLCB_t *object;
    lcb_t instance;

    mk_instance_vars(self, instance, object);
    plcb_cleanup(object);
    Safefree(object);

SV *
PLCB_get(self, key)
    SV *    self
    SV *    key


SV *
PLCB_touch(self, key, exp_offset)
    SV *self
    SV *key
    UV exp_offset;

SV *
PLCB__set(self, key, value, ...)
    SV *self
    SV *key
    SV *value

    ALIAS:
    set         = PLCB_CMD_SET
    add         = PLCB_CMD_ADD
    replace     = PLCB_CMD_REPLACE
    append      = PLCB_CMD_APPEND
    prepend     = PLCB_CMD_PREPEND

    couch_add   = PLCB_CMD_COUCH_ADD
    couch_set   = PLCB_CMD_COUCH_SET
    couch_replace= PLCB_CMD_COUCH_REPLACE

    PREINIT:
    UV exp_offset = 0;
    int cmd_base;

    CODE:
    set_plst_get_offset(4, exp_offset, "USAGE: set(key, value [,expiry]");
    cmd_base = (ix & PLCB_COMMAND_MASK);


    if( (cmd_base == PLCB_CMD_APPEND || cmd_base == PLCB_CMD_PREPEND)
       && SvROK(value) ) {
        die("Cannot append/prepend a reference");
    }

    RETVAL = PLCB_set_common(
        self, key, value,
        ix,
        exp_offset, 0);

    OUTPUT:
    RETVAL


SV *
PLCB_arithmetic(self, key, ...)
    SV *self
    SV *key

    ALIAS:
    incr        = 1
    decr        = 2

    PREINIT:
    int64_t delta;
    UV exp_offset;
    SV *initial;
    SV *delta_sv;
    int do_create;
    uint64_t initial_i;

    CODE:
    do_create     = 0;
    exp_offset     = 0;
    initial_i     = 0;
    initial     = NULL;
    delta_sv    = NULL;


    if(items > 2) {
        delta_sv = ST(2);
    }

    if(ix == 0) {
        if(items < 4 || items > 5) {
            die("arithmetic(key, delta, initial [,expiry])");
        }

        if(SvTYPE( (initial=ST(3)) ) == SVt_NULL) {
            do_create = 0;
        } else {
            do_create = 1;
            initial_i = plcb_sv_to_u64(initial);
        }

        if(items == 5 && (exp_offset = SvUV( ST(4) )) == 0 ) {
            die("Expiry offset cannot be 0");
        }
        delta = plcb_sv_to_64(delta_sv);
    } else {
        if(items < 2 || items > 3) {
            die("Usage: incr/decr(key [,delta])");
        }
        delta = (delta_sv) ? plcb_sv_to_64(delta_sv) : 1;
        delta = (ix == 2) ? -delta : delta;
    }

    RETVAL = PLCB_arithmetic_common(
        self, key, delta, do_create, initial_i, exp_offset);

    OUTPUT:
    RETVAL


SV *
PLCB__cas(self, key, value, cas_sv, ...)
    SV *self
    SV *key
    SV *value
    SV *cas_sv

    ALIAS:
    cas = PLCB_CMD_CAS
    couch_cas = PLCB_CMD_COUCH_CAS

    PREINIT:
    UV exp_offset = 0;
    uint64_t *cas_val = NULL;
    int cmd;

    CODE:
    if(SvTYPE(cas_sv) == SVt_NULL) {
        /*don't bother the network if we know our CAS operation will fail*/
        warn("I was given a null cas!");
        RETVAL = return_empty(self,
            LCB_KEY_EEXISTS, "I was given an undef cas");
        return;
    }

    plcb_cas_from_sv(cas_sv, cas_val, cas_len);

    set_plst_get_offset(5, exp_offset, "USAGE: cas(key,value,cas[,expiry])");

    cmd =  PLCB_CMD_SET | (ix & PLCB_COMMAND_EXTRA_MASK);

    RETVAL = PLCB_set_common(
        self, key, value,
        cmd,
        exp_offset, *cas_val);
    assert(RETVAL != &PL_sv_undef);
    OUTPUT:
    RETVAL


SV *
PLCB_remove(self, key, ...)
    SV *self
    SV *key

    ALIAS:
    delete = 1

    PREINIT:
    uint64_t *cas_ptr = NULL;
    SV *cas_sv;

    CODE:
    if(items == 2) {
        RETVAL = PLCB_remove(self, key, 0);
    } else {
        cas_sv = ST(2);
        plcb_cas_from_sv(cas_sv, cas_ptr, cas_len);
        RETVAL = PLCB_remove(self, key, *cas_ptr);
    }

    OUTPUT:
    RETVAL

SV *
PLCB_observe(self, key, ...)
    SV *self
    SV *key
    PREINIT:
    uint64_t *cas_ptr = NULL;
    SV *cas_sv;

    CODE:
    if (items == 2) {
        RETVAL = PLCB_observe(self, key, 0);
    } else {
        cas_sv = ST(2);
        plcb_cas_from_sv(cas_sv, cas_ptr, cas_len);
        RETVAL = PLCB_observe(self, key, *cas_ptr);
    }

    OUTPUT: RETVAL

SV *
PLCB_get_errors(self)
    SV *self

    PREINIT:
    lcb_t instance;
    PLCB_t *object;

    CODE:
    mk_instance_vars(self, instance, object);
    RETVAL = newRV_inc((SV*)object->errors);

    OUTPUT:
    RETVAL


SV *
PLCB_stats(self, ...)
    SV *self

    PREINIT:
    SV *klist;

    CODE:
    if( items < 2 ) {
        klist = NULL;
    } else {
        klist = ST(1);
        if(! (SvROK(klist) && SvTYPE(SvRV(klist)) >= SVt_PVAV) ) {
            die("Usage: stats( ['some', 'keys', ...] )");
        }
    }
    RETVAL = PLCB_stats(self, (klist) ? (AV*)SvRV(klist) : NULL);

    OUTPUT:
    RETVAL


IV
PLCB__settings(self, ...)
    SV *self

    ALIAS:
    enable_compress             = SETTINGS_ALIAS_COMPRESS_COMPAT
    compression_settings        = SETTINGS_ALIAS_COMPRESS
    serialization_settings      = SETTINGS_ALIAS_SERIALIZE
    conversion_settings         = SETTINGS_ALIAS_CONVERT
    deconversion_settings       = SETTINGS_ALIAS_DECONVERT
    compress_threshold          = SETTINGS_ALIAS_COMP_THRESHOLD
    dereference_scalar_ref_settings  = SETTINGS_ALIAS_DEREF_RVPV

    PREINIT:
    int flag = 0;
    int new_value = 0;
    lcb_t instance;
    PLCB_t *object;

    CODE:
    mk_instance_vars(self, instance, object);
    switch(ix) {
        case SETTINGS_ALIAS_COMPRESS:
        case SETTINGS_ALIAS_COMPRESS_COMPAT:
            flag = PLCBf_USE_COMPRESSION;
            break;
        case SETTINGS_ALIAS_SERIALIZE:
            flag = PLCBf_USE_STORABLE;
            break;
        case SETTINGS_ALIAS_CONVERT:
            flag = PLCBf_USE_STORABLE|PLCBf_USE_COMPRESSION;
            break;
        case SETTINGS_ALIAS_DECONVERT:
            flag = PLCBf_DECONVERT;
            break;
        case SETTINGS_ALIAS_COMP_THRESHOLD:
            flag = PLCBf_COMPRESS_THRESHOLD;
            break;
        case SETTINGS_ALIAS_DEREF_RVPV:
            flag = PLCBf_DEREF_RVPV;
            break;
        case 0:
            die("This function should not be called directly. "
                "use one of its aliases");
        default:
            die("Wtf?");
            break;
    }
    if(items == 2) {
        new_value = sv_2bool(ST(1));
    } else if (items == 1) {
        new_value = -1;
    } else {
        die("%s(self, [value])", GvNAME(GvCV(cv)));
    }

    if(!SvROK(self)) {
        die("%s: I was given a bad object", GvNAME(GvCV(cv)));
    }



    RETVAL = plcb_convert_settings(object, flag, new_value);
    //warn("Report flag %d = %d", flag, RETVAL);

    OUTPUT:
    RETVAL


NV
PLCB_timeout(self, ...)
    SV *self

    PREINIT:
    NV new_param;
    uint32_t usecs;
    NV ret;

    lcb_t instance;
    PLCB_t *object;

    CODE:

    mk_instance_vars(self, instance, object);

    ret = ((NV)(lcb_get_timeout(instance))) / (1000*1000);

    if(items == 2) {
        new_param = SvNV(ST(1));
        if(new_param <= 0) {
            warn("Cannot disable timeouts.");
            XSRETURN_UNDEF;
        }
        usecs = new_param * (1000*1000);
        lcb_set_timeout(instance, usecs);
    }

    RETVAL = ret;

    OUTPUT:
    RETVAL

int
PLCB_connect(self)
    SV *self


BOOT:
/*XXX: DO NOT MODIFY WHITESPACE HERE. xsubpp is touchy*/
#define PLCB_BOOTSTRAP_DEPENDENCY(bootfunc) \
PUSHMARK(SP); \
mXPUSHs(newSVpv("Couchbase::Client", sizeof("Couchbase::Client")-1)); \
mXPUSHs(newSVpv(XS_VERSION, sizeof(XS_VERSION)-1)); \
PUTBACK; \
bootfunc(aTHX_ cv); \
SPAGAIN;
{
    {
        lcb_uint32_t cbc_version = 0;
        const char *cbc_version_string;
        cbc_version_string = lcb_get_version(&cbc_version);
        /*
        warn("Couchbase library version is (%s) %x",
             cbc_version_string, cbc_version);
        */
    }
    /*Client_multi.xs*/
    PLCB_BOOTSTRAP_DEPENDENCY(boot_Couchbase__Client_multi);
    /* Couch_request_handle.xs */
    PLCB_BOOTSTRAP_DEPENDENCY(boot_Couchbase__Client_couch);
    /* Iterator_get.xs */
    PLCB_BOOTSTRAP_DEPENDENCY(boot_Couchbase__Client_iterator);
}
#undef PLCB_BOOTSTRAP_DEPENDENCY

INCLUDE: Async.xs
