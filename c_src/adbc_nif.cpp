#include <cstdbool>
#include <cstdio>
#include <climits>
#include <nanoarrow/nanoarrow.h>
#include <nanoarrow/nanoarrow_ipc.h>
#include <nanoarrow/nanoarrow_ipc.hpp>
#include <arrow-adbc/adbc.h>
#include <erl_nif.h>
#include "adbc_nif_resource.hpp"
#include "nif_utils.hpp"
#include "adbc_consts.h"
#include "adbc_column.hpp"
#include "adbc_arrow_schema.hpp"
#include "adbc_arrow_array.hpp"

template<> ErlNifResourceType * NifRes<struct AdbcDatabase>::type = nullptr;
template<> ErlNifResourceType * NifRes<struct AdbcConnection>::type = nullptr;
template<> ErlNifResourceType * NifRes<struct AdbcStatement>::type = nullptr;
template<> ErlNifResourceType * NifRes<struct AdbcError>::type = nullptr;
template<> ErlNifResourceType * NifRes<struct ArrowArrayStream>::type = nullptr;
template<> ErlNifResourceType * NifRes<struct ArrowArrayStreamRecord>::type = nullptr;
template<> ErlNifResourceType * NifRes<struct AdbcDeleteOnGC>::type = nullptr;

static ERL_NIF_TERM nif_error_from_arrow_error(ErlNifEnv *env, struct ArrowError * arrow_error) {
    return erlang::nif::error(env, enif_make_tuple4(env,
        kAtomAdbcError,
        erlang::nif::make_binary(env, arrow_error->message),
        kAtomNil,
        kAtomNil
    ));
}

static ERL_NIF_TERM nif_error_from_adbc_error(ErlNifEnv *env, struct AdbcError * adbc_error) {
    char const* message = (adbc_error->message == nullptr) ? "unknown error" : adbc_error->message;
    ERL_NIF_TERM nif_error = erlang::nif::error(env, enif_make_tuple4(env,
        kAtomAdbcError,
        erlang::nif::make_binary(env, message),
        enif_make_int(env, adbc_error->vendor_code),
        erlang::nif::make_binary(env, adbc_error->sqlstate, 5)
    ));

    if (adbc_error->release != nullptr) {
        adbc_error->release(adbc_error);
    }

    return nif_error;
}

static ERL_NIF_TERM adbc_database_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcDatabase>;

    ERL_NIF_TERM error{};
    auto database = res_type::allocate_resource(env, error);
    if (database == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcDatabaseNew(&database->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    ERL_NIF_TERM ret = database->make_resource(env);
    return erlang::nif::ok(env, ret);
}

template <typename T, typename GetString, typename GetBytes, typename GetInt, typename GetDouble>
static ERL_NIF_TERM adbc_get_option(ErlNifEnv *env, const ERL_NIF_TERM argv[], GetString& get_string, GetBytes& get_bytes, GetInt& get_int, GetDouble& get_double) {
    using res_type = NifRes<T>;

    ERL_NIF_TERM error{};
    res_type * resource = nullptr;
    if ((resource = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    std::string type, key;
    if (!erlang::nif::get_atom(env, argv[1], type)) {
        return enif_make_badarg(env);
    }
    if (!erlang::nif::get(env, argv[2], key)) {
        return enif_make_badarg(env);
    }

    struct AdbcError adbc_error{};
    if (type == "string" || type == "binary") {
        int is_string = type == "string";
        uint8_t value[64] = {'\0'};
        constexpr size_t value_buffer_size = sizeof(value) / sizeof(value[0]);
        size_t value_len = value_buffer_size;
        AdbcStatusCode code;
        size_t elem_size = 0;
        if (is_string) {
            elem_size = sizeof(char);
            code = get_string(&resource->val, key.c_str(), (char *)value, &value_len, &adbc_error);
        } else {
            elem_size = sizeof(uint8_t);
            code = get_bytes(&resource->val, key.c_str(), value, &value_len, &adbc_error);
        }
        if (code != ADBC_STATUS_OK) {
            return nif_error_from_adbc_error(env, &adbc_error);
        }

        if (value_len > value_buffer_size) {
            uint8_t * out_value = (uint8_t *)enif_alloc(elem_size * (value_len + 1));
            memset(out_value, 0, elem_size * (value_len + 1));
            value_len += 1;
            if (is_string) {
                code = get_string(&resource->val, key.c_str(), (char *)out_value, &value_len, &adbc_error);
            } else {
                code = get_bytes(&resource->val, key.c_str(), out_value, &value_len, &adbc_error);
            }

            if (code != ADBC_STATUS_OK) {
                return nif_error_from_adbc_error(env, &adbc_error);
            }

            // minus 1 to remove the null terminator for strings
            ERL_NIF_TERM ret;
            ret = erlang::nif::make_binary(env, (const char *)out_value, value_len - (is_string ? 1 : 0));
            enif_free(out_value);
            return erlang::nif::ok(env, ret);
        } else {
            // minus 1 to remove the null terminator for strings
            return erlang::nif::ok(env, erlang::nif::make_binary(env, (const char *)value, value_len - (is_string ? 1 : 0)));
        }
    } else if (type == "integer") {
        int64_t value = 0;
        AdbcStatusCode code = get_int(&resource->val, key.c_str(), &value, &adbc_error);
        if (code != ADBC_STATUS_OK) {
            return nif_error_from_adbc_error(env, &adbc_error);
        }

        return erlang::nif::ok(env, erlang::nif::make(env, value));
    } else if (type == "float") {
        double value = 0;
        AdbcStatusCode code = get_double(&resource->val, key.c_str(), &value, &adbc_error);
        if (code != ADBC_STATUS_OK) {
            return nif_error_from_adbc_error(env, &adbc_error);
        }

        return erlang::nif::ok(env, erlang::nif::make(env, value));
    } else {
        return enif_make_badarg(env);
    }
}

template <typename T, typename SetString, typename SetBytes, typename SetInt, typename SetDouble>
static ERL_NIF_TERM adbc_set_option(ErlNifEnv *env, const ERL_NIF_TERM argv[], SetString& set_string, SetBytes &set_bytes, SetInt &set_int, SetDouble &set_double) {
    using res_type = NifRes<T>;

    ERL_NIF_TERM error{};
    res_type * resource = nullptr;
    if ((resource = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    std::string type, key;
    if (!erlang::nif::get_atom(env, argv[1], type)) {
        return enif_make_badarg(env);
    }
    if (!erlang::nif::get(env, argv[2], key)) {
        return enif_make_badarg(env);
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code;
    if (type == "string" || type == "binary") {
        if (type == "string") {
            std::string value;
            if (!erlang::nif::get(env, argv[3], value)) {
                return enif_make_badarg(env);
            }
            code = set_string(&resource->val, key.c_str(), value.c_str(), &adbc_error);
        } else {
            ErlNifBinary bin;
            int ret = enif_inspect_iolist_as_binary(env, argv[3], &bin);
            if (!ret) {
                return enif_make_badarg(env);
            }
            code = set_bytes(&resource->val, key.c_str(), bin.data, bin.size, &adbc_error);
        }
    } else if (type == "integer") {
        int64_t value;
        if (!erlang::nif::get(env, argv[3], &value)) {
            return enif_make_badarg(env);
        }
        code = set_int(&resource->val, key.c_str(), value, &adbc_error);
    } else if (type == "float") {
        double value;
        if (!erlang::nif::get(env, argv[3], &value)) {
            return enif_make_badarg(env);
        }
        code = set_double(&resource->val, key.c_str(), value, &adbc_error);
    } else {
        return enif_make_badarg(env);
    }

    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }
    return erlang::nif::ok(env);
}

static ERL_NIF_TERM adbc_database_get_option(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return adbc_get_option<struct AdbcDatabase>(
        env,
        argv,
        AdbcDatabaseGetOption,
        AdbcDatabaseGetOptionBytes,
        AdbcDatabaseGetOptionInt,
        AdbcDatabaseGetOptionDouble
    );
}

static ERL_NIF_TERM adbc_database_set_option(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return adbc_set_option<struct AdbcDatabase>(
        env,
        argv,
        AdbcDatabaseSetOption,
        AdbcDatabaseSetOptionBytes,
        AdbcDatabaseSetOptionInt,
        AdbcDatabaseSetOptionDouble
    );
}

static ERL_NIF_TERM adbc_database_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcDatabase>;

    ERL_NIF_TERM error{};
    res_type * database = nullptr;
    if ((database = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcDatabaseInit(&database->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    return erlang::nif::ok(env);
}

static ERL_NIF_TERM adbc_connection_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcConnection>;

    ERL_NIF_TERM error{};
    auto connection = res_type::allocate_resource(env, error);
    if (connection == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcConnectionNew(&connection->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    ERL_NIF_TERM ret = connection->make_resource(env);
    return erlang::nif::ok(env, ret);
}

static ERL_NIF_TERM adbc_connection_get_option(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return adbc_get_option<struct AdbcConnection>(
        env,
        argv,
        AdbcConnectionGetOption,
        AdbcConnectionGetOptionBytes,
        AdbcConnectionGetOptionInt,
        AdbcConnectionGetOptionDouble
    );
}

static ERL_NIF_TERM adbc_connection_set_option(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return adbc_set_option<struct AdbcConnection>(
        env,
        argv,
        AdbcConnectionSetOption,
        AdbcConnectionSetOptionBytes,
        AdbcConnectionSetOptionInt,
        AdbcConnectionSetOptionDouble
    );
}

static ERL_NIF_TERM adbc_connection_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcConnection>;
    using db_type = NifRes<struct AdbcDatabase>;

    ERL_NIF_TERM error{};
    res_type * connection = nullptr;
    db_type * db = nullptr;
    if ((connection = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }
    if ((db = db_type::get_resource(env, argv[1], error)) == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcConnectionInit(&connection->val, &db->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    connection->private_data = &db->val;
    enif_keep_resource(&db->val);
    return erlang::nif::ok(env);
}

static ERL_NIF_TERM adbc_connection_get_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcConnection>;
    using array_stream_type = NifRes<struct ArrowArrayStream>;

    ERL_NIF_TERM error{};
    res_type * connection = nullptr;
    if ((connection = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    std::vector<uint32_t> info_codes;
    if (!erlang::nif::get_list(env, argv[1], info_codes)) {
        return enif_make_badarg(env);
    }
    uint32_t* ptr = nullptr;
    size_t info_codes_length = info_codes.size();
    if (info_codes_length != 0) {
        ptr = info_codes.data();
    }

    auto array_stream = array_stream_type::allocate_resource(env, error);
    if (array_stream == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcConnectionGetInfo(&connection->val, ptr, info_codes_length, &array_stream->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    ERL_NIF_TERM ret = array_stream->make_resource(env);
    return erlang::nif::ok(env, ret);
}

static ERL_NIF_TERM adbc_connection_get_objects(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcConnection>;
    using array_stream_type = NifRes<struct ArrowArrayStream>;

    ERL_NIF_TERM error{};
    res_type * connection = nullptr;
    if ((connection = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    int depth;
    std::string catalog, db_schema, table_name;
    std::vector<ErlNifBinary> table_type;
    std::string column_name;
    const char * catalog_p = nullptr;
    const char * db_schema_p = nullptr;
    const char * table_name_p = nullptr;
    const char * column_name_p = nullptr;

    if (!erlang::nif::get(env, argv[1], &depth)) {
        return enif_make_badarg(env);
    }
    if (!erlang::nif::get(env, argv[2], catalog)) {
        if (!erlang::nif::check_nil(env, argv[2])) {
            return enif_make_badarg(env);
        } else {
            catalog_p = catalog.c_str();
        }
    }
    if (!erlang::nif::get(env, argv[3], db_schema)) {
        if (!erlang::nif::check_nil(env, argv[3])) {
            return enif_make_badarg(env);
        } else {
            db_schema_p = db_schema.c_str();
        }
    }
    if (!erlang::nif::get(env, argv[4], table_name)) {
        if (!erlang::nif::check_nil(env, argv[4])) {
            return enif_make_badarg(env);
        } else {
            table_name_p = table_name.c_str();
        }
    }
    if (!erlang::nif::get_list(env, argv[5], table_type)) {
        if (!erlang::nif::check_nil(env, argv[5])) {
            return enif_make_badarg(env);
        }
    }
    if (!erlang::nif::get(env, argv[6], column_name)) {
        if (!erlang::nif::check_nil(env, argv[6])) {
            return enif_make_badarg(env);
        } else {
            column_name_p = column_name.c_str();
        }
    }

    std::vector<const char *> table_types;
    for (auto& tt : table_type) {
        char * t = (char *)enif_alloc(tt.size + 1);
        if (t == nullptr) {
            for (auto& at : table_types) {
                enif_free((void *)at);
            }
            return erlang::nif::error(env, "out of memory");
        }
        memcpy(t, tt.data, tt.size);
        t[tt.size] = '\0';
        table_types.emplace_back(t);
    }
    // Terminate the list with a NULL entry.
    table_types.emplace_back(nullptr);

    auto array_stream = array_stream_type::allocate_resource(env, error);
    if (array_stream == nullptr) {
        for (auto& at : table_types) {
            if (at) enif_free((void *)at);
        }
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcConnectionGetObjects(
        &connection->val,
        depth,
        catalog_p,
        db_schema_p,
        table_name_p,
        table_types.data(),
        column_name_p,
        &array_stream->val,
        &adbc_error);
    if (code != ADBC_STATUS_OK) {
        for (auto& at : table_types) {
            if (at) enif_free((void *)at);
        }
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    ERL_NIF_TERM ret = array_stream->make_resource(env);
    for (auto& at : table_types) {
        if (at) enif_free((void *)at);
    }

    return enif_make_tuple2(env, erlang::nif::ok(env), ret);
}

static ERL_NIF_TERM adbc_connection_get_table_types(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcConnection>;
    using array_stream_type = NifRes<struct ArrowArrayStream>;

    ERL_NIF_TERM error{};
    res_type * connection = nullptr;
    if ((connection = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    auto array_stream = array_stream_type::allocate_resource(env, error);
    if (array_stream == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcConnectionGetTableTypes(&connection->val, &array_stream->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    ERL_NIF_TERM ret = array_stream->make_resource(env);

    return enif_make_tuple2(env, erlang::nif::ok(env), ret);
}

static ERL_NIF_TERM adbc_arrow_array_stream_get_pointer(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct ArrowArrayStream>;
    ERL_NIF_TERM error{};

    res_type * res = nullptr;
    if ((res = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    return enif_make_uint64(env, reinterpret_cast<uint64_t>(&res->val));
}

static ERL_NIF_TERM adbc_arrow_array_stream_from_pointer(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct ArrowArrayStream>;
    ERL_NIF_TERM error{};

    ErlNifUInt64 pointer = 0;
    if (!enif_get_uint64(env, argv[0], &pointer)) {
        return enif_make_badarg(env);
    }

    auto array_stream = res_type::allocate_resource(env, error);
    if (array_stream == nullptr) {
        return error;
    }

    // We want to take full ownership of the stream, so we copy it
    // into our resource-managed memory and we disable the release
    // on the source, so that we are the ones responsible for
    // releasing the stream.
    auto source = reinterpret_cast<struct ArrowArrayStream *>(pointer);
    memcpy(&array_stream->val, source, sizeof(struct ArrowArrayStream));
    source->release = nullptr;

    return erlang::nif::ok(env, array_stream->make_resource(env));
}

static ERL_NIF_TERM adbc_arrow_array_stream_next(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct ArrowArrayStream>;
    ERL_NIF_TERM error{};

    res_type * res = nullptr;
    struct ArrowSchema * schema = nullptr;
    struct ArrowArray array{};
    std::vector<ERL_NIF_TERM> out_terms;

    if ((res = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }
    if (res->val.get_next == nullptr) {
        return enif_make_badarg(env);
    }

    int code = res->val.get_next(&res->val, &array);
    if (code != 0) {
        const char * reason = res->val.get_last_error(&res->val);
        return erlang::nif::error(env, reason ? reason : "unknown error: cannot get next record with record->val.values");
    }
    // if no error and the array is released, the stream has ended
    if (array.release == nullptr) {
        return kAtomEndOfSeries;
    }

    // only allocate priv data once for the entire stream
    if (res->private_data == nullptr) {
        const char * reason = nullptr;
        res->private_data = enif_alloc(sizeof(struct ArrowSchema));
        if (res->private_data != nullptr) {
            memset(res->private_data, 0, sizeof(struct ArrowSchema));
            code = res->val.get_schema(&res->val, (struct ArrowSchema *)res->private_data);
        } else {
            reason = "out of memory";
        }

        // if `res->private_data` was null, `code` will still be 0
        if (code != 0) {
            reason = res->val.get_last_error(&res->val);
            enif_free(res->private_data);
            res->private_data = nullptr;
        }

        if (res->private_data == nullptr) {
            error = erlang::nif::error(env, reason ? reason : "unknown error");
            if (array.release) {
                array.release(&array);
            }
            return error;
        }
    }
    schema = (struct ArrowSchema *)res->private_data;
    code = arrow_schema_to_nif_term(env, schema, &array, out_terms, error);
    // the outter array should be released because we have moved the values
    // for each column to the corresponding reference in `Adbc.Column.data`
    if (array.release) {
        array.release(&array);
    }

    if (code != 0) {
        // If arrow_schema_to_nif_term failed without setting an error term,
        // produce a generic error rather than returning an invalid term.
        if (error == 0) {
            return erlang::nif::error(env, "failed to convert Arrow schema to Elixir term");
        }
        return error;
    } else {
        return erlang::nif::ok(env, out_terms[0]);
    }
}

static ERL_NIF_TERM adbc_column_materialize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using record_type = NifRes<struct ArrowArrayStreamRecord>;

    if (!enif_is_ref(env, argv[0])) {
        return enif_make_badarg(env);
    }

    ERL_NIF_TERM error{};
    record_type * res = record_type::get_resource(env, argv[0], error);
    if (res == nullptr) {
        return error;
    }
    if (res->val.schema == nullptr || res->val.values == nullptr) {
        return enif_make_badarg(env);
    }

    std::vector<ERL_NIF_TERM> out_terms;
    constexpr int level = 0;
    ERL_NIF_TERM out_type;
    ERL_NIF_TERM out_metadata;
    if (arrow_array_to_nif_term(env, res->val.schema, res->val.values, level, out_terms, out_type, out_metadata, error, false, (void*)res) != 0) {
        return error;
    }

    ERL_NIF_TERM ret = (out_terms.size() == 1) ? out_terms[0] : out_terms[1];
    return erlang::nif::ok(env, enif_make_tuple2(env, ret, enif_make_int64(env, res->val.values->length)));
}

static ERL_NIF_TERM adbc_arrow_array_stream_release(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct ArrowArrayStream>;
    ERL_NIF_TERM error{};

    res_type * res = nullptr;
    if ((res = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    if (res->val.release) {
        res->val.release(&res->val);
        res->val.release = nullptr;
    }

    return erlang::nif::ok(env);
}

static ERL_NIF_TERM adbc_statement_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcStatement>;
    using connection_type = NifRes<struct AdbcConnection>;

    ERL_NIF_TERM error{};

    connection_type * connection = nullptr;
    if ((connection = connection_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    auto statement = res_type::allocate_resource(env, error);
    if (statement == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcStatementNew(&connection->val, &statement->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    connection->private_data = &connection->val;
    enif_keep_resource(&connection->val);
    ERL_NIF_TERM ret = statement->make_resource(env);
    return erlang::nif::ok(env, ret);
}

static ERL_NIF_TERM adbc_statement_get_option(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return adbc_get_option<struct AdbcStatement>(
        env,
        argv,
        AdbcStatementGetOption,
        AdbcStatementGetOptionBytes,
        AdbcStatementGetOptionInt,
        AdbcStatementGetOptionDouble
    );
}

static ERL_NIF_TERM adbc_statement_set_option(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return adbc_set_option<struct AdbcStatement>(
        env,
        argv,
        AdbcStatementSetOption,
        AdbcStatementSetOptionBytes,
        AdbcStatementSetOptionInt,
        AdbcStatementSetOptionDouble
    );
}

static ERL_NIF_TERM adbc_statement_execute_query(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcStatement>;
    using array_stream_type = NifRes<struct ArrowArrayStream>;

    ERL_NIF_TERM error{};

    res_type * statement = nullptr;
    if ((statement = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    auto array_stream = array_stream_type::allocate_resource(env, error);
    if (array_stream == nullptr) {
        return error;
    }

    int64_t rows_affected = 0;
    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcStatementExecuteQuery(&statement->val, &array_stream->val, &rows_affected, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    ERL_NIF_TERM ret = array_stream->make_resource(env);
    return enif_make_tuple3(env,
        erlang::nif::ok(env),
        ret,
        enif_make_int64(env, rows_affected)
    );
}

static ERL_NIF_TERM adbc_statement_execute(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcStatement>;

    ERL_NIF_TERM error{};

    res_type * statement = nullptr;
    if ((statement = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    int64_t rows_affected = 0;
    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcStatementExecuteQuery(&statement->val, nullptr, &rows_affected, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    return enif_make_tuple2(env,
        erlang::nif::ok(env),
        enif_make_int64(env, rows_affected)
    );
}

static ERL_NIF_TERM adbc_statement_prepare(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcStatement>;

    ERL_NIF_TERM error{};

    res_type * statement = nullptr;
    if ((statement = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcStatementPrepare(&statement->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    return erlang::nif::ok(env);
}

static ERL_NIF_TERM adbc_statement_set_sql_query(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcStatement>;

    ERL_NIF_TERM error{};

    res_type * statement = nullptr;
    if ((statement = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    std::string query;
    if (!erlang::nif::get(env, argv[1], query)) {
        return enif_make_badarg(env);
    }

    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcStatementSetSqlQuery(&statement->val, query.c_str(), &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    return erlang::nif::ok(env);
}

static ERL_NIF_TERM adbc_statement_bind(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcStatement>;

    ERL_NIF_TERM ret{};
    ERL_NIF_TERM error{};

    res_type * statement = nullptr;
    if ((statement = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    if (!enif_is_list(env, argv[1])) {
        return enif_make_badarg(env);
    }

    struct ArrowArray values{};
    struct ArrowSchema schema{};
    struct ArrowError arrow_error{};
    struct AdbcError adbc_error{};
    AdbcStatusCode code{};
    values.release = nullptr;
    schema.release = nullptr;

    if (adbc_column_to_arrow_type_struct(env, argv[1], &values, &schema, &arrow_error)) {
        ret = erlang::nif::error(env, arrow_error.message);
        goto cleanup;
    }

    code = AdbcStatementBind(&statement->val, &values, &schema, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        ret = nif_error_from_adbc_error(env, &adbc_error);
        goto cleanup;
    }
    ret = erlang::nif::ok(env);

cleanup:
    if (values.release) values.release(&values);
    if (schema.release) schema.release(&schema);
    return ret;
}

static ERL_NIF_TERM adbc_statement_bind_stream(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcStatement>;
    using array_stream_type = NifRes<struct ArrowArrayStream>;

    ERL_NIF_TERM error{};

    res_type * statement = nullptr;
    if ((statement = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }

    array_stream_type * stream = nullptr;
    if ((stream = array_stream_type::get_resource(env, argv[1], error)) == nullptr) {
        return error;
    }
    struct AdbcError adbc_error{};
    AdbcStatusCode code = AdbcStatementBindStream(&statement->val, &stream->val, &adbc_error);
    if (code != ADBC_STATUS_OK) {
        return nif_error_from_adbc_error(env, &adbc_error);
    }

    return erlang::nif::ok(env);
}

static ERL_NIF_TERM adbc_ipc_load_stream_binary(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using array_stream_type = NifRes<struct ArrowArrayStream>;

    nanoarrow::UniqueBuffer input_buffer;
    ERL_NIF_TERM error{};
    std::vector<ERL_NIF_TERM> out_terms;

    ErlNifBinary binary{};
    if (!erlang::nif::get(env, argv[0], &binary)) return enif_make_badarg(env);

    ArrowErrorCode code = ArrowBufferAppend(input_buffer.get(), binary.data, binary.size);
    if (code != NANOARROW_OK) {
        return erlang::nif::error(env, "Failed to append binary data to Arrow IPC input buffer");
    }

    struct ArrowIpcInputStream input;
    code = ArrowIpcInputStreamInitBuffer(&input, input_buffer.get());
    if (code != NANOARROW_OK) {
        return erlang::nif::error(env, "Failed to initialize Arrow IPC array stream");
    }

    auto array_stream = array_stream_type::allocate_resource(env, error);
    if (array_stream == nullptr) {
        return error;
    }

    code = ArrowIpcArrayStreamReaderInit(&array_stream->val, &input, nullptr);
    if (code != NANOARROW_OK) {
        return erlang::nif::error(env, "Failed to initialize Arrow IPC array stream reader");
    }

    return array_stream->make_resource(env);
}

// Private data for an ArrowArrayStream built from Elixir columns.
// Holds the schema and one record batch; the stream yields that single batch
// and then signals end-of-stream.
struct ColumnsStreamPrivate {
    struct ArrowSchema schema;
    struct ArrowArray   array;
    bool consumed;  // true after get_next has returned the batch
};

static int columns_stream_get_schema(struct ArrowArrayStream *stream, struct ArrowSchema *out) {
    auto *priv = static_cast<ColumnsStreamPrivate *>(stream->private_data);
    return ArrowSchemaDeepCopy(&priv->schema, out);
}

static int columns_stream_get_next(struct ArrowArrayStream *stream, struct ArrowArray *out) {
    auto *priv = static_cast<ColumnsStreamPrivate *>(stream->private_data);
    if (priv->consumed) {
        // Signal end-of-stream
        out->release = nullptr;
        return 0;
    }
    // Move the array to the caller — transfers ownership of all buffers.
    memcpy(out, &priv->array, sizeof(struct ArrowArray));
    // Prevent double-free: the caller now owns the array.
    priv->array.release = nullptr;
    priv->consumed = true;
    return 0;
}

static const char *columns_stream_get_last_error(struct ArrowArrayStream *) {
    return nullptr;
}

static void columns_stream_release(struct ArrowArrayStream *stream) {
    if (stream->private_data) {
        auto *priv = static_cast<ColumnsStreamPrivate *>(stream->private_data);
        if (priv->schema.release) priv->schema.release(&priv->schema);
        if (priv->array.release)  priv->array.release(&priv->array);
        delete priv;
        stream->private_data = nullptr;
    }
    stream->release = nullptr;
}

// Build an ArrowArrayStream resource from a list of Adbc.Column structs.
// The resulting stream yields a single record batch, then ends.
static ERL_NIF_TERM adbc_columns_to_arrow_array_stream(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct ArrowArrayStream>;

    if (!enif_is_list(env, argv[0])) {
        return enif_make_badarg(env);
    }

    struct ArrowError arrow_error{};
    auto *priv = new (std::nothrow) ColumnsStreamPrivate{};
    if (!priv) {
        return erlang::nif::error(env, "out of memory");
    }
    memset(&priv->schema, 0, sizeof(struct ArrowSchema));
    memset(&priv->array, 0, sizeof(struct ArrowArray));
    priv->consumed = false;
    priv->schema.release = nullptr;

    if (adbc_column_to_arrow_type_struct(env, argv[0], &priv->array, &priv->schema, &arrow_error)) {
        ERL_NIF_TERM ret = erlang::nif::error(env, arrow_error.message);
        if (priv->schema.release) priv->schema.release(&priv->schema);
        if (priv->array.release)  priv->array.release(&priv->array);
        delete priv;
        return ret;
    }

    ERL_NIF_TERM error{};
    auto stream_res = res_type::allocate_resource(env, error);
    if (stream_res == nullptr) {
        if (priv->schema.release) priv->schema.release(&priv->schema);
        if (priv->array.release)  priv->array.release(&priv->array);
        delete priv;
        return error;
    }

    stream_res->val.get_schema     = columns_stream_get_schema;
    stream_res->val.get_next       = columns_stream_get_next;
    stream_res->val.get_last_error = columns_stream_get_last_error;
    stream_res->val.release        = columns_stream_release;
    stream_res->val.private_data   = priv;

    return erlang::nif::ok(env, stream_res->make_resource(env));
}

// Serialize an ArrowArrayStream directly to IPC bytes.
// Consumes the stream — drains all batches and writes schema + batches + EOS.
static ERL_NIF_TERM adbc_arrow_array_stream_to_ipc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct ArrowArrayStream>;
    ERL_NIF_TERM error{};

    res_type *res = nullptr;
    if ((res = res_type::get_resource(env, argv[0], error)) == nullptr) {
        return error;
    }
    if (res->val.release == nullptr) {
        return erlang::nif::error(env, "stream has already been released");
    }

    struct ArrowSchema schema{};
    schema.release = nullptr;
    struct ArrowError arrow_error{};
    ERL_NIF_TERM ret{};

    // Get the schema from the stream
    int code = res->val.get_schema(&res->val, &schema);
    if (code != 0) {
        const char *reason = res->val.get_last_error(&res->val);
        return erlang::nif::error(env, reason ? reason : "failed to get schema from stream");
    }

    // Set up IPC writer
    nanoarrow::UniqueBuffer output;
    nanoarrow::ipc::UniqueOutputStream ostream;
    code = ArrowIpcOutputStreamInitBuffer(ostream.get(), output.get());
    if (code != NANOARROW_OK) {
        ret = erlang::nif::error(env, "failed to initialize IPC output stream");
        goto cleanup;
    }

    {
        nanoarrow::ipc::UniqueWriter writer;
        code = ArrowIpcWriterInit(writer.get(), ostream.get());
        if (code != NANOARROW_OK) {
            ret = erlang::nif::error(env, "failed to initialize IPC writer");
            goto cleanup;
        }

        code = ArrowIpcWriterWriteSchema(writer.get(), &schema, &arrow_error);
        if (code != NANOARROW_OK) {
            ret = nif_error_from_arrow_error(env, &arrow_error);
            goto cleanup;
        }

        // Drain all batches from the stream
        while (true) {
            struct ArrowArray array{};
            code = res->val.get_next(&res->val, &array);
            if (code != 0) {
                const char *reason = res->val.get_last_error(&res->val);
                ret = erlang::nif::error(env, reason ? reason : "failed to get next batch");
                goto cleanup;
            }
            if (array.release == nullptr) {
                // End of stream
                break;
            }

            nanoarrow::UniqueArrayView array_view;
            code = ArrowArrayViewInitFromSchema(array_view.get(), &schema, &arrow_error);
            if (code != NANOARROW_OK) {
                array.release(&array);
                ret = nif_error_from_arrow_error(env, &arrow_error);
                goto cleanup;
            }
            code = ArrowArrayViewSetArray(array_view.get(), &array, &arrow_error);
            if (code != NANOARROW_OK) {
                array.release(&array);
                ret = nif_error_from_arrow_error(env, &arrow_error);
                goto cleanup;
            }

            code = ArrowIpcWriterWriteArrayView(writer.get(), array_view.get(), &arrow_error);
            array.release(&array);
            if (code != NANOARROW_OK) {
                ret = nif_error_from_arrow_error(env, &arrow_error);
                goto cleanup;
            }
        }

        // Write end-of-stream marker
        code = ArrowIpcWriterWriteArrayView(writer.get(), nullptr, &arrow_error);
        if (code != NANOARROW_OK) {
            ret = nif_error_from_arrow_error(env, &arrow_error);
            goto cleanup;
        }

        ArrowIpcWriterReset(writer.get());
    }

    {
        ErlNifBinary binary;
        if (!enif_alloc_binary(output->size_bytes, &binary)) {
            ret = erlang::nif::error(env, "out of memory");
            goto cleanup;
        }
        memcpy(binary.data, output->data, output->size_bytes);
        ret = erlang::nif::ok(env, enif_make_binary(env, &binary));
    }

cleanup:
    if (schema.release) schema.release(&schema);
    return ret;
}

// argv[0] is a list of batches, each batch is a list of columns
static ERL_NIF_TERM adbc_ipc_dump_stream_binary(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (!enif_is_list(env, argv[0])) {
        return enif_make_badarg(env);
    }

    AdbcStatusCode code{};
    struct ArrowSchema schema{};
    struct ArrowError arrow_error{};
    nanoarrow::UniqueBuffer output;
    nanoarrow::ipc::UniqueOutputStream stream;
    code = ArrowIpcOutputStreamInitBuffer(stream.get(), output.get());
    if (code != NANOARROW_OK) {
        return erlang::nif::error(env, "Failed to initialize Arrow IPC output stream and buffer");
    }

    nanoarrow::ipc::UniqueWriter writer;
    code = ArrowIpcWriterInit(writer.get(), stream.get());
    if (code != NANOARROW_OK) {
        return erlang::nif::error(env, "Failed to initialize Arrow IPC writer");
    }

    schema.release = nullptr;
    bool schema_written = false;
    ERL_NIF_TERM ret{};

    ERL_NIF_TERM batch_head, batch_tail = argv[0];
    while (enif_get_list_cell(env, batch_tail, &batch_head, &batch_tail)) {
        nanoarrow::UniqueArray array;
        if (adbc_column_to_arrow_type_struct(env, batch_head, array.get(), &schema, &arrow_error)) {
            ret = erlang::nif::error(env, arrow_error.message);
            goto cleanup;
        }

        if (!schema_written) {
            code = ArrowIpcWriterWriteSchema(writer.get(), &schema, &arrow_error);
            if (code != NANOARROW_OK) {
                ret = nif_error_from_arrow_error(env, &arrow_error);
                goto cleanup;
            }
            schema_written = true;
        }

        nanoarrow::UniqueArrayView array_view;
        code = ArrowArrayViewInitFromSchema(array_view.get(), &schema, &arrow_error);
        if (code != NANOARROW_OK) {
            ret = nif_error_from_arrow_error(env, &arrow_error);
            goto cleanup;
        }

        code = ArrowArrayViewSetArray(array_view.get(), array.get(), &arrow_error);
        if (code != NANOARROW_OK) {
            ret = nif_error_from_arrow_error(env, &arrow_error);
            goto cleanup;
        }

        code = ArrowIpcWriterWriteArrayView(writer.get(), array_view.get(), &arrow_error);
        if (code != NANOARROW_OK) {
            ret = nif_error_from_arrow_error(env, &arrow_error);
            goto cleanup;
        }

        // Release schema from this batch (will be rebuilt for next batch)
        if (schema.release) {
            schema.release(&schema);
            schema.release = nullptr;
        }
    }

    // write `nullptr` to end the stream
    code = ArrowIpcWriterWriteArrayView(writer.get(), nullptr, &arrow_error);
    if (code != NANOARROW_OK) {
        ret = nif_error_from_arrow_error(env, &arrow_error);
        goto cleanup;
    }

    {
        ErlNifBinary binary;
        if (!enif_alloc_binary(output->size_bytes, &binary)) {
            ret = erlang::nif::error(env, "out of memory");
            goto cleanup;
        }

        memcpy(binary.data, output->data, output->size_bytes);
        ArrowIpcWriterReset(writer.get());
        ret = erlang::nif::ok(env, enif_make_binary(env, &binary));
    }

cleanup:
    if (schema.release) schema.release(&schema);
    return ret;
}

static ERL_NIF_TERM adbc_ipc_system_endianness(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (ArrowIpcSystemEndianness() == NANOARROW_IPC_ENDIANNESS_BIG) {
        return kAtomBig;
    } else {
        return kAtomLittle;
    }
}

static ERL_NIF_TERM adbc_delete_on_gc_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    using res_type = NifRes<struct AdbcDeleteOnGC>;

    ERL_NIF_TERM error{};

    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[0], &pid)) {
        return enif_make_badarg(env);
    }

    std::string table_name;
    if (!erlang::nif::get(env, argv[1], table_name)) {
        return enif_make_badarg(env);
    }

    res_type *res = res_type::allocate_resource(env, error);
    if (res == nullptr) {
        return error;
    }

    res->val.pid = pid;
    new (&res->val.table_name) std::string(std::move(table_name));

    ERL_NIF_TERM ref = res->make_resource(env);
    enif_release_resource(res);
    return ref;
}

static int on_load(ErlNifEnv *env, void **, ERL_NIF_TERM) {
    ErlNifResourceType *rt;

    {
        using res_type = NifRes<struct AdbcDatabase>;
        rt = enif_open_resource_type(env, "Elixir.Adbc.Nif", "NifResAdbcDatabase", destruct_adbc_database_resource, ERL_NIF_RT_CREATE, NULL);
        if (!rt) return -1;
        res_type::type = rt;
    }

    {
        using res_type = NifRes<struct AdbcConnection>;
        rt = enif_open_resource_type(env, "Elixir.Adbc.Nif", "NifResAdbcConnection", destruct_adbc_connection_resource, ERL_NIF_RT_CREATE, NULL);
        if (!rt) return -1;
        res_type::type = rt;
    }

    {
        using res_type = NifRes<struct AdbcStatement>;
        rt = enif_open_resource_type(env, "Elixir.Adbc.Nif", "NifResAdbcStatement", destruct_adbc_statement_resource, ERL_NIF_RT_CREATE, NULL);
        if (!rt) return -1;
        res_type::type = rt;
    }

    {
        using res_type = NifRes<struct AdbcError>;
        rt = enif_open_resource_type(env, "Elixir.Adbc.Nif", "NifResAdbcError", destruct_adbc_error, ERL_NIF_RT_CREATE, NULL);
        if (!rt) return -1;
        res_type::type = rt;
    }

    {
        using res_type = NifRes<struct ArrowArrayStream>;
        rt = enif_open_resource_type(env, "Elixir.Adbc.Nif", "NifResArrowArrayStream", destruct_adbc_arrow_array_stream, ERL_NIF_RT_CREATE, NULL);
        if (!rt) return -1;
        res_type::type = rt;
    }

    {
        using res_type = NifRes<struct ArrowArrayStreamRecord>;
        rt = enif_open_resource_type(env, "Elixir.Adbc.Nif", "NifResArrowArrayStreamRecord", destruct_arrow_array_stream_record, ERL_NIF_RT_CREATE, NULL);
        if (!rt) return -1;
        res_type::type = rt;
    }

    {
        using res_type = NifRes<struct AdbcDeleteOnGC>;
        rt = enif_open_resource_type(env, "Elixir.Adbc.Nif", "NifResAdbcDeleteOnGC", destruct_adbc_delete_on_gc, ERL_NIF_RT_CREATE, NULL);
        if (!rt) return -1;
        res_type::type = rt;
    }

    kAtomAdbcError = erlang::nif::atom(env, "adbc_error");
    kAtomNil = erlang::nif::atom(env, "nil");
    kAtomTrue = erlang::nif::atom(env, "true");
    kAtomFalse = erlang::nif::atom(env, "false");
    kAtomKey = erlang::nif::atom(env, "key");
    kAtomValue = erlang::nif::atom(env, "value");
    kAtomInfinity = erlang::nif::atom(env, "infinity");
    kAtomNegInfinity = erlang::nif::atom(env, "neg_infinity");
    kAtomNaN = erlang::nif::atom(env, "nan");
    kAtomBig = erlang::nif::atom(env, "big");
    kAtomLittle = erlang::nif::atom(env, "little");
    kAtomEndOfSeries = erlang::nif::atom(env, "end_of_series");
    kAtomStructKey = erlang::nif::atom(env, "__struct__");
    kAtomValidity = erlang::nif::atom(env, "validity");
    kAtomOffsets = erlang::nif::atom(env, "offsets");
    kAtomSizes = erlang::nif::atom(env, "sizes");
    kAtomValues = erlang::nif::atom(env, "values");
    kAtomRunEnds = erlang::nif::atom(env, "run_ends");

    kAtomDecimal128 = erlang::nif::atom(env, "decimal128");
    kAtomDecimal256 = erlang::nif::atom(env, "decimal256");
    kAtomFixedSizeBinary = erlang::nif::atom(env, "fixed_size_binary");
    kAtomFixedSizeList = erlang::nif::atom(env, "fixed_size_list");
    kAtomTime32 = erlang::nif::atom(env, "time32");
    kAtomTime64 = erlang::nif::atom(env, "time64");
    kAtomTimestamp = erlang::nif::atom(env, "timestamp");
    kAtomDuration = erlang::nif::atom(env, "duration");
    kAtomInterval = erlang::nif::atom(env, "interval");
    kAtomSeconds = erlang::nif::atom(env, "seconds");
    kAtomMilliseconds = erlang::nif::atom(env, "milliseconds");
    kAtomMicroseconds = erlang::nif::atom(env, "microseconds");
    kAtomNanoseconds = erlang::nif::atom(env, "nanoseconds");
    kAtomMonth = erlang::nif::atom(env, "month");
    kAtomDayTime = erlang::nif::atom(env, "day_time");
    kAtomMonthDayNano = erlang::nif::atom(env, "month_day_nano");


    kAtomAdbcColumnModule = erlang::nif::atom(env, "Elixir.Adbc.Column");
    kAtomAdbcFieldModule = erlang::nif::atom(env, "Elixir.Adbc.Field");
    kAtomAdbcDictionaryDataModule = erlang::nif::atom(env, "Elixir.Adbc.DictionaryData");
    kAtomAdbcRunEndEncodedDataModule = erlang::nif::atom(env, "Elixir.Adbc.RunEndEncodedData");
    kAtomAdbcListViewDataModule = erlang::nif::atom(env, "Elixir.Adbc.ListViewData");
    kAtomAdbcListDataModule = erlang::nif::atom(env, "Elixir.Adbc.ListData");
    kAtomAdbcBufferDataModule = erlang::nif::atom(env, "Elixir.Adbc.BufferData");
    kAtomAdbcBinaryDataModule = erlang::nif::atom(env, "Elixir.Adbc.BinaryData");
    kAtomAdbcStructDataModule = erlang::nif::atom(env, "Elixir.Adbc.StructData");
    kAtomAdbcBooleanDataModule = erlang::nif::atom(env, "Elixir.Adbc.BooleanData");
    kAtomFieldKey = erlang::nif::atom(env, "field");
    kAtomNameKey = erlang::nif::atom(env, "name");
    kAtomTypeKey = erlang::nif::atom(env, "type");
    kAtomMetadataKey = erlang::nif::atom(env, "metadata");
    kAtomDataKey = erlang::nif::atom(env, "data");
    kAtomSizeKey = erlang::nif::atom(env, "size");
    kAtomLengthKey = erlang::nif::atom(env, "length");
    kAtomOffsetKey = erlang::nif::atom(env, "offset");
    kAtomBitOffsetKey = erlang::nif::atom(env, "bit_offset");

    kAdbcColumnTypeBool = erlang::nif::atom(env, "boolean");
    kAdbcColumnTypeS8 = erlang::nif::atom(env, "s8");
    kAdbcColumnTypeU8 = erlang::nif::atom(env, "u8");
    kAdbcColumnTypeS16 = erlang::nif::atom(env, "s16");
    kAdbcColumnTypeU16 = erlang::nif::atom(env, "u16");
    kAdbcColumnTypeS32 = erlang::nif::atom(env, "s32");
    kAdbcColumnTypeU32 = erlang::nif::atom(env, "u32");
    kAdbcColumnTypeS64 = erlang::nif::atom(env, "s64");
    kAdbcColumnTypeU64 = erlang::nif::atom(env, "u64");
    kAdbcColumnTypeF16 = erlang::nif::atom(env, "f16");
    kAdbcColumnTypeF32 = erlang::nif::atom(env, "f32");
    kAdbcColumnTypeF64 = erlang::nif::atom(env, "f64");
    kAdbcColumnTypeBinary = erlang::nif::atom(env, "binary");
    kAdbcColumnTypeLargeBinary = erlang::nif::atom(env, "large_binary");
    kAdbcColumnTypeBinaryView = erlang::nif::atom(env, "binary_view");
    kAdbcColumnTypeString = erlang::nif::atom(env, "string");
    kAdbcColumnTypeLargeString = erlang::nif::atom(env, "large_string");
    kAdbcColumnTypeStringView = erlang::nif::atom(env, "string_view");
    kAdbcColumnTypeDate32 = erlang::nif::atom(env, "date32");
    kAdbcColumnTypeDate64 = erlang::nif::atom(env, "date64");
    kAdbcColumnTypeList = erlang::nif::atom(env, "list");
    kAdbcColumnTypeLargeList = erlang::nif::atom(env, "large_list");
    kAdbcColumnTypeListView = erlang::nif::atom(env, "list_view");
    kAdbcColumnTypeLargeListView = erlang::nif::atom(env, "large_list_view");
    kAdbcColumnTypeStruct = erlang::nif::atom(env, "struct");
    kAdbcColumnTypeMap = erlang::nif::atom(env, "map");
    kAdbcColumnTypeDenseUnion = erlang::nif::atom(env, "dense_union");
    kAdbcColumnTypeSparseUnion = erlang::nif::atom(env, "sparse_union");
    kAdbcColumnTypeRunEndEncoded = erlang::nif::atom(env, "run_end_encoded");
    kAdbcColumnTypeDictionary = erlang::nif::atom(env, "dictionary");

    primitiveFormatMapping = {
        {"n", {kAtomNil}},
        {"b", {kAdbcColumnTypeBool}},
        {"c", {kAdbcColumnTypeS8}},
        {"C", {kAdbcColumnTypeU8}},
        {"s", {kAdbcColumnTypeS16}},
        {"S", {kAdbcColumnTypeU16}},
        {"i", {kAdbcColumnTypeS32}},
        {"I", {kAdbcColumnTypeU32}},
        {"l", {kAdbcColumnTypeS64}},
        {"L", {kAdbcColumnTypeU64}},
        {"e", {kAdbcColumnTypeF16}},
        {"f", {kAdbcColumnTypeF32}},
        {"g", {kAdbcColumnTypeF64}},
        {"z", {kAdbcColumnTypeBinary}},
        {"Z", {kAdbcColumnTypeLargeBinary}},
        {"vz", {kAdbcColumnTypeBinaryView}},
        {"u", {kAdbcColumnTypeString}},
        {"U", {kAdbcColumnTypeLargeString}},
        {"vu", {kAdbcColumnTypeStringView}},
        {"tdD", {kAdbcColumnTypeDate32}},
        {"tdm", {kAdbcColumnTypeDate64}},
        // we cannot call enif_make_tuple2 here and reuse the tuple later
        // it has to be generated each time
        {"tts", {kAtomTime32, kAtomSeconds}},
        {"ttm", {kAtomTime32, kAtomMilliseconds}},
        {"ttu", {kAtomTime64, kAtomMicroseconds}},
        {"ttn", {kAtomTime64, kAtomNanoseconds}},
        {"tDs", {kAtomDuration, kAtomSeconds}},
        {"tDm", {kAtomDuration, kAtomMilliseconds}},
        {"tDu", {kAtomDuration, kAtomMicroseconds}},
        {"tDn", {kAtomDuration, kAtomNanoseconds}},
        {"tiM", {kAtomInterval, kAtomMonth}},
        {"tiD", {kAtomInterval, kAtomDayTime}},
        {"tin", {kAtomInterval, kAtomMonthDayNano}},
    };

    return 0;
}

static int on_reload(ErlNifEnv *, void **, ERL_NIF_TERM) {
    return 0;
}

static int on_upgrade(ErlNifEnv *, void **, void **, ERL_NIF_TERM) {
    return 0;
}

static ErlNifFunc nif_functions[] = {
    {"adbc_database_new", 0, adbc_database_new, 0},
    {"adbc_database_get_option", 3, adbc_database_get_option, 0},
    {"adbc_database_set_option", 4, adbc_database_set_option, 0},
    {"adbc_database_init", 1, adbc_database_init, ERL_NIF_DIRTY_JOB_IO_BOUND},

    {"adbc_connection_new", 0, adbc_connection_new, 0},
    {"adbc_connection_get_option", 3, adbc_connection_get_option, 0},
    {"adbc_connection_set_option", 4, adbc_connection_set_option, 0},
    {"adbc_connection_init", 2, adbc_connection_init, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_connection_get_info", 2, adbc_connection_get_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_connection_get_objects", 7, adbc_connection_get_objects, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_connection_get_table_types", 1, adbc_connection_get_table_types, ERL_NIF_DIRTY_JOB_IO_BOUND},

    {"adbc_statement_new", 1, adbc_statement_new, 0},
    {"adbc_statement_get_option", 3, adbc_statement_get_option, 0},
    {"adbc_statement_set_option", 4, adbc_statement_set_option, 0},
    {"adbc_statement_execute_query", 1, adbc_statement_execute_query, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_statement_execute", 1, adbc_statement_execute, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_statement_prepare", 1, adbc_statement_prepare, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_statement_set_sql_query", 2, adbc_statement_set_sql_query, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_statement_bind", 2, adbc_statement_bind, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_statement_bind_stream", 2, adbc_statement_bind_stream, ERL_NIF_DIRTY_JOB_IO_BOUND},

    {"adbc_arrow_array_stream_get_pointer", 1, adbc_arrow_array_stream_get_pointer, 0},
    {"adbc_arrow_array_stream_from_pointer", 1, adbc_arrow_array_stream_from_pointer, 0},
    {"adbc_arrow_array_stream_next", 1, adbc_arrow_array_stream_next, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adbc_arrow_array_stream_release", 1, adbc_arrow_array_stream_release, ERL_NIF_DIRTY_JOB_IO_BOUND},

    {"adbc_column_materialize", 1, adbc_column_materialize, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"adbc_delete_on_gc_new", 2, adbc_delete_on_gc_new, 0},

    {"adbc_columns_to_arrow_array_stream", 1, adbc_columns_to_arrow_array_stream, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"adbc_arrow_array_stream_to_ipc", 1, adbc_arrow_array_stream_to_ipc, ERL_NIF_DIRTY_JOB_CPU_BOUND},

    {"adbc_ipc_system_endianness", 0, adbc_ipc_system_endianness, 0},
    {"adbc_ipc_load_stream_binary", 1, adbc_ipc_load_stream_binary, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"adbc_ipc_dump_stream_binary", 1, adbc_ipc_dump_stream_binary, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(Elixir.Adbc.Nif, nif_functions, on_load, on_reload, on_upgrade, NULL);
