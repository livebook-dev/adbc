#include <arrow-adbc/adbc.h>
#include <cstdbool>
#include <cstdio>
#include <fine.hpp>
#include <nanoarrow/nanoarrow.h>
#include <nanoarrow/nanoarrow_ipc.h>
#include <nanoarrow/nanoarrow_ipc.hpp>

#include "adbc_arrow_array.hpp"
#include "adbc_arrow_array_stream_record.hpp"
#include "adbc_arrow_schema.hpp"
#include "adbc_column.hpp"
#include "adbc_consts.h"

FINE_RESOURCE(ArrowArrayStreamRecord);

// Fine resource wrappers

struct AdbcDatabaseResource {
  struct AdbcDatabase value{};

  void destructor(ErlNifEnv *env) {
    struct AdbcError adbc_error{};
    AdbcDatabaseRelease(&value, &adbc_error);
  }
};
FINE_RESOURCE(AdbcDatabaseResource);

struct AdbcConnectionResource {
  struct AdbcConnection value{};
  fine::ResourcePtr<AdbcDatabaseResource> database;

  void destructor(ErlNifEnv *env) {
    struct AdbcError adbc_error{};
    AdbcConnectionRelease(&value, &adbc_error);
  }
};
FINE_RESOURCE(AdbcConnectionResource);

struct AdbcStatementResource {
  struct AdbcStatement value{};
  fine::ResourcePtr<AdbcConnectionResource> connection;

  void destructor(ErlNifEnv *env) {
    struct AdbcError adbc_error{};
    AdbcStatementRelease(&value, &adbc_error);
  }
};
FINE_RESOURCE(AdbcStatementResource);

struct ArrowArrayStreamResource {
  struct ArrowArrayStream value{};
  struct ArrowSchema schema{};
  // Keeps the statement alive while reading.
  fine::ResourcePtr<AdbcStatementResource> statement;

  void destructor(ErlNifEnv *env) {
    if (schema.release)
      schema.release(&schema);
    // val.release is not called here intentionally - must be done explicitly
    // via adbc_arrow_array_stream_release
  }
};
FINE_RESOURCE(ArrowArrayStreamResource);

struct AdbcExecuteOnGCResource {
  ErlNifPid pid{};
  std::string statement;

  void destructor(ErlNifEnv *env) {
    auto msg_env = enif_alloc_env();
    if (msg_env) {
      auto statement_term = fine::encode(msg_env, statement);
      auto msg = enif_make_tuple2(msg_env, kAtomExecuteOnGC, statement_term);
      enif_send(NULL, &pid, msg_env, msg);
      enif_free_env(msg_env);
    }
  }
};
FINE_RESOURCE(AdbcExecuteOnGCResource);

// Error helpers

static fine::Term adbc_error_term(ErlNifEnv *env,
                                  struct AdbcError *adbc_error) {
  const char *message =
      (adbc_error->message == nullptr) ? "unknown error" : adbc_error->message;
  auto term = fine::Term(enif_make_tuple4(
      env, kAtomAdbcError, fine::encode(env, std::string_view(message)),
      enif_make_int(env, adbc_error->vendor_code),
      fine::make_new_binary(env, adbc_error->sqlstate, 5)));
  if (adbc_error->release != nullptr) {
    adbc_error->release(adbc_error);
  }
  return term;
}

static fine::Term arrow_error_term(ErlNifEnv *env,
                                   struct ArrowError *arrow_error) {
  return fine::Term(enif_make_tuple4(
      env, kAtomAdbcError,
      fine::encode(env, std::string_view(arrow_error->message)), kAtomNil,
      kAtomNil));
}

// Type alias for ADBC results
template <typename... T>
using AdbcResult = std::variant<fine::Ok<T...>, fine::Error<fine::Term>>;

// Get/set option template helpers

template <typename ResType, typename GetString, typename GetBytes,
          typename GetInt, typename GetDouble>
static fine::Term
adbc_get_option_impl(ErlNifEnv *env, fine::ResourcePtr<ResType> res,
                     const fine::Atom &type_atom, const std::string &key,
                     GetString get_string, GetBytes get_bytes, GetInt get_int,
                     GetDouble get_double) {
  const std::string &type = type_atom.to_string();
  struct AdbcError adbc_error{};

  if (type == "string" || type == "binary") {
    int is_string = (type == "string");
    uint8_t value[64] = {'\0'};
    constexpr size_t value_buffer_size = sizeof(value) / sizeof(value[0]);
    size_t value_len = value_buffer_size;
    AdbcStatusCode code;
    size_t elem_size;

    if (is_string) {
      elem_size = sizeof(char);
      code = get_string(&res->value, key.c_str(), (char *)value, &value_len,
                        &adbc_error);
    } else {
      elem_size = sizeof(uint8_t);
      code =
          get_bytes(&res->value, key.c_str(), value, &value_len, &adbc_error);
    }
    if (code != ADBC_STATUS_OK) {
      return fine::encode(env, fine::Error(adbc_error_term(env, &adbc_error)));
    }

    if (value_len > value_buffer_size) {
      uint8_t *out_value = (uint8_t *)enif_alloc(elem_size * (value_len + 1));
      memset(out_value, 0, elem_size * (value_len + 1));
      size_t len2 = value_len + 1;
      if (is_string) {
        code = get_string(&res->value, key.c_str(), (char *)out_value, &len2,
                          &adbc_error);
      } else {
        code =
            get_bytes(&res->value, key.c_str(), out_value, &len2, &adbc_error);
      }
      if (code != ADBC_STATUS_OK) {
        enif_free(out_value);
        return fine::encode(env,
                            fine::Error(adbc_error_term(env, &adbc_error)));
      }
      // minus 1 to remove the null terminator for strings
      auto ret = fine::make_new_binary(env, (const char *)out_value,
                                       value_len - (is_string ? 1 : 0));
      enif_free(out_value);
      return fine::encode(env, fine::Ok(fine::Term(ret)));
    } else {
      // minus 1 to remove the null terminator for strings
      auto ret = fine::make_new_binary(env, (const char *)value,
                                       value_len - (is_string ? 1 : 0));
      return fine::encode(env, fine::Ok(fine::Term(ret)));
    }
  } else if (type == "integer") {
    int64_t value = 0;
    AdbcStatusCode code =
        get_int(&res->value, key.c_str(), &value, &adbc_error);
    if (code != ADBC_STATUS_OK) {
      return fine::encode(env, fine::Error(adbc_error_term(env, &adbc_error)));
    }
    return fine::encode(env, fine::Ok(fine::Term(enif_make_int64(env, value))));
  } else if (type == "float") {
    double value = 0;
    AdbcStatusCode code =
        get_double(&res->value, key.c_str(), &value, &adbc_error);
    if (code != ADBC_STATUS_OK) {
      return fine::encode(env, fine::Error(adbc_error_term(env, &adbc_error)));
    }
    return fine::encode(env,
                        fine::Ok(fine::Term(enif_make_double(env, value))));
  } else {
    throw std::invalid_argument(
        "invalid option type, expected :string, :binary, :integer, or :float");
  }
}

template <typename ResType, typename SetString, typename SetBytes,
          typename SetInt, typename SetDouble>
static AdbcResult<>
adbc_set_option_impl(ErlNifEnv *env, fine::ResourcePtr<ResType> res,
                     const fine::Atom &type_atom, const std::string &key,
                     fine::Term value_term, SetString set_string,
                     SetBytes set_bytes, SetInt set_int, SetDouble set_double) {
  const std::string &type = type_atom.to_string();
  struct AdbcError adbc_error{};
  AdbcStatusCode code;

  if (type == "string") {
    auto value = fine::decode<std::string>(env, value_term);
    code = set_string(&res->value, key.c_str(), value.c_str(), &adbc_error);
  } else if (type == "binary") {
    auto bin = fine::decode<ErlNifBinary>(env, value_term);
    code = set_bytes(&res->value, key.c_str(), bin.data, bin.size, &adbc_error);
  } else if (type == "integer") {
    auto value = fine::decode<int64_t>(env, value_term);
    code = set_int(&res->value, key.c_str(), value, &adbc_error);
  } else if (type == "float") {
    auto value = fine::decode<double>(env, value_term);
    code = set_double(&res->value, key.c_str(), value, &adbc_error);
  } else {
    throw std::invalid_argument(
        "invalid option type, expected :string, :binary, :integer, or :float");
  }

  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok<>();
}

// NIF functions

AdbcResult<fine::ResourcePtr<AdbcDatabaseResource>>
adbc_database_new(ErlNifEnv *env) {
  auto db = fine::make_resource<AdbcDatabaseResource>();
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcDatabaseNew(&db->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok(db);
}
FINE_NIF(adbc_database_new, 0);

fine::Term adbc_database_get_option(ErlNifEnv *env,
                                    fine::ResourcePtr<AdbcDatabaseResource> db,
                                    fine::Atom type, std::string key) {
  return adbc_get_option_impl(
      env, db, type, key, AdbcDatabaseGetOption, AdbcDatabaseGetOptionBytes,
      AdbcDatabaseGetOptionInt, AdbcDatabaseGetOptionDouble);
}
FINE_NIF(adbc_database_get_option, 0);

AdbcResult<>
adbc_database_set_option(ErlNifEnv *env,
                         fine::ResourcePtr<AdbcDatabaseResource> db,
                         fine::Atom type, std::string key, fine::Term value) {
  return adbc_set_option_impl(env, db, type, key, value, AdbcDatabaseSetOption,
                              AdbcDatabaseSetOptionBytes,
                              AdbcDatabaseSetOptionInt,
                              AdbcDatabaseSetOptionDouble);
}
FINE_NIF(adbc_database_set_option, 0);

AdbcResult<> adbc_database_init(ErlNifEnv *env,
                                fine::ResourcePtr<AdbcDatabaseResource> db) {
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcDatabaseInit(&db->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok<>();
}
FINE_NIF(adbc_database_init, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<fine::ResourcePtr<AdbcConnectionResource>>
adbc_connection_new(ErlNifEnv *env) {
  auto conn = fine::make_resource<AdbcConnectionResource>();
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcConnectionNew(&conn->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok(conn);
}
FINE_NIF(adbc_connection_new, 0);

fine::Term
adbc_connection_get_option(ErlNifEnv *env,
                           fine::ResourcePtr<AdbcConnectionResource> conn,
                           fine::Atom type, std::string key) {
  return adbc_get_option_impl(env, conn, type, key, AdbcConnectionGetOption,
                              AdbcConnectionGetOptionBytes,
                              AdbcConnectionGetOptionInt,
                              AdbcConnectionGetOptionDouble);
}
FINE_NIF(adbc_connection_get_option, 0);

AdbcResult<>
adbc_connection_set_option(ErlNifEnv *env,
                           fine::ResourcePtr<AdbcConnectionResource> conn,
                           fine::Atom type, std::string key, fine::Term value) {
  return adbc_set_option_impl(
      env, conn, type, key, value, AdbcConnectionSetOption,
      AdbcConnectionSetOptionBytes, AdbcConnectionSetOptionInt,
      AdbcConnectionSetOptionDouble);
}
FINE_NIF(adbc_connection_set_option, 0);

AdbcResult<>
adbc_connection_init(ErlNifEnv *env,
                     fine::ResourcePtr<AdbcConnectionResource> conn,
                     fine::ResourcePtr<AdbcDatabaseResource> db) {
  struct AdbcError adbc_error{};
  AdbcStatusCode code =
      AdbcConnectionInit(&conn->value, &db->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  conn->database = db;
  return fine::Ok<>();
}
FINE_NIF(adbc_connection_init, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<fine::ResourcePtr<ArrowArrayStreamResource>>
adbc_connection_get_info(ErlNifEnv *env,
                         fine::ResourcePtr<AdbcConnectionResource> conn,
                         std::vector<uint64_t> info_codes) {
  auto stream_res = fine::make_resource<ArrowArrayStreamResource>();
  std::vector<uint32_t> info_codes_u32(info_codes.begin(), info_codes.end());
  uint32_t *ptr = nullptr;
  size_t info_codes_length = info_codes_u32.size();
  if (info_codes_length != 0) {
    ptr = info_codes_u32.data();
  }
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcConnectionGetInfo(
      &conn->value, ptr, info_codes_length, &stream_res->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok(stream_res);
}
FINE_NIF(adbc_connection_get_info, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<fine::ResourcePtr<ArrowArrayStreamResource>>
adbc_connection_get_objects(
    ErlNifEnv *env, fine::ResourcePtr<AdbcConnectionResource> conn,
    int64_t depth, std::optional<std::string> catalog,
    std::optional<std::string> db_schema, std::optional<std::string> table_name,
    std::optional<std::vector<std::string>> table_type_opt,
    std::optional<std::string> column_name) {
  const char *catalog_p = catalog ? catalog->c_str() : "";
  const char *db_schema_p = db_schema ? db_schema->c_str() : "";
  const char *table_name_p = table_name ? table_name->c_str() : "";
  const char *column_name_p = column_name ? column_name->c_str() : "";

  std::vector<std::string> table_type_strs;
  std::vector<const char *> table_types;

  if (table_type_opt) {
    table_type_strs = std::move(*table_type_opt);
    for (const auto &tt : table_type_strs) {
      table_types.emplace_back(tt.c_str());
    }
  }
  // Terminate the list with a NULL entry.
  table_types.emplace_back(nullptr);

  auto stream_res = fine::make_resource<ArrowArrayStreamResource>();
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcConnectionGetObjects(
      &conn->value, (int)depth, catalog_p, db_schema_p, table_name_p,
      table_types.data(), column_name_p, &stream_res->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok(stream_res);
}
FINE_NIF(adbc_connection_get_objects, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<fine::ResourcePtr<ArrowArrayStreamResource>>
adbc_connection_get_table_types(
    ErlNifEnv *env, fine::ResourcePtr<AdbcConnectionResource> conn) {
  auto stream_res = fine::make_resource<ArrowArrayStreamResource>();
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcConnectionGetTableTypes(
      &conn->value, &stream_res->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok(stream_res);
}
FINE_NIF(adbc_connection_get_table_types, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<fine::ResourcePtr<AdbcStatementResource>>
adbc_statement_new(ErlNifEnv *env,
                   fine::ResourcePtr<AdbcConnectionResource> conn) {
  auto stmt = fine::make_resource<AdbcStatementResource>();
  struct AdbcError adbc_error{};
  AdbcStatusCode code =
      AdbcStatementNew(&conn->value, &stmt->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  stmt->connection = conn;
  return fine::Ok(stmt);
}
FINE_NIF(adbc_statement_new, 0);

fine::Term
adbc_statement_get_option(ErlNifEnv *env,
                          fine::ResourcePtr<AdbcStatementResource> stmt,
                          fine::Atom type, std::string key) {
  return adbc_get_option_impl(
      env, stmt, type, key, AdbcStatementGetOption, AdbcStatementGetOptionBytes,
      AdbcStatementGetOptionInt, AdbcStatementGetOptionDouble);
}
FINE_NIF(adbc_statement_get_option, 0);

AdbcResult<>
adbc_statement_set_option(ErlNifEnv *env,
                          fine::ResourcePtr<AdbcStatementResource> stmt,
                          fine::Atom type, std::string key, fine::Term value) {
  return adbc_set_option_impl(
      env, stmt, type, key, value, AdbcStatementSetOption,
      AdbcStatementSetOptionBytes, AdbcStatementSetOptionInt,
      AdbcStatementSetOptionDouble);
}
FINE_NIF(adbc_statement_set_option, 0);

AdbcResult<fine::ResourcePtr<ArrowArrayStreamResource>, int64_t>
adbc_statement_execute_query(ErlNifEnv *env,
                             fine::ResourcePtr<AdbcStatementResource> stmt) {
  auto stream_res = fine::make_resource<ArrowArrayStreamResource>();
  int64_t rows_affected = 0;
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcStatementExecuteQuery(
      &stmt->value, &stream_res->value, &rows_affected, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  stream_res->statement = stmt;
  return fine::Ok(stream_res, rows_affected);
}
FINE_NIF(adbc_statement_execute_query, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<int64_t>
adbc_statement_execute(ErlNifEnv *env,
                       fine::ResourcePtr<AdbcStatementResource> stmt) {
  int64_t rows_affected = 0;
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcStatementExecuteQuery(&stmt->value, nullptr,
                                                  &rows_affected, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok(rows_affected);
}
FINE_NIF(adbc_statement_execute, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<>
adbc_statement_prepare(ErlNifEnv *env,
                       fine::ResourcePtr<AdbcStatementResource> stmt) {
  struct AdbcError adbc_error{};
  AdbcStatusCode code = AdbcStatementPrepare(&stmt->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok<>();
}
FINE_NIF(adbc_statement_prepare, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<>
adbc_statement_set_sql_query(ErlNifEnv *env,
                             fine::ResourcePtr<AdbcStatementResource> stmt,
                             std::string query) {
  struct AdbcError adbc_error{};
  AdbcStatusCode code =
      AdbcStatementSetSqlQuery(&stmt->value, query.c_str(), &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok<>();
}
FINE_NIF(adbc_statement_set_sql_query, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<> adbc_statement_bind(ErlNifEnv *env,
                                 fine::ResourcePtr<AdbcStatementResource> stmt,
                                 fine::Term values_term) {
  ERL_NIF_TERM values = values_term;
  if (!enif_is_list(env, values)) {
    throw std::invalid_argument("expected a list of columns");
  }

  struct ArrowArray arr{};
  struct ArrowSchema schema{};
  struct ArrowError arrow_error{};
  arr.release = nullptr;
  schema.release = nullptr;

  AdbcResult<> ret;

  if (adbc_column_to_arrow_type_struct(env, values, &arr, &schema,
                                       &arrow_error)) {
    ret = fine::Error(
        fine::Term(fine::encode(env, std::string_view(arrow_error.message))));
  } else {
    struct AdbcError adbc_error{};
    AdbcStatusCode code =
        AdbcStatementBind(&stmt->value, &arr, &schema, &adbc_error);
    if (code != ADBC_STATUS_OK) {
      ret = fine::Error(adbc_error_term(env, &adbc_error));
    } else {
      ret = fine::Ok<>();
    }
  }

  if (arr.release)
    arr.release(&arr);
  if (schema.release)
    schema.release(&schema);
  return ret;
}
FINE_NIF(adbc_statement_bind, ERL_NIF_DIRTY_JOB_IO_BOUND);

AdbcResult<>
adbc_statement_bind_stream(ErlNifEnv *env,
                           fine::ResourcePtr<AdbcStatementResource> stmt,
                           fine::ResourcePtr<ArrowArrayStreamResource> stream) {
  struct AdbcError adbc_error{};
  AdbcStatusCode code =
      AdbcStatementBindStream(&stmt->value, &stream->value, &adbc_error);
  if (code != ADBC_STATUS_OK) {
    return fine::Error(adbc_error_term(env, &adbc_error));
  }
  return fine::Ok<>();
}
FINE_NIF(adbc_statement_bind_stream, ERL_NIF_DIRTY_JOB_IO_BOUND);

uint64_t adbc_arrow_array_stream_get_pointer(
    ErlNifEnv *env, fine::ResourcePtr<ArrowArrayStreamResource> res) {
  return reinterpret_cast<uint64_t>(&res->value);
}
FINE_NIF(adbc_arrow_array_stream_get_pointer, 0);

fine::Ok<fine::ResourcePtr<ArrowArrayStreamResource>>
adbc_arrow_array_stream_from_pointer(ErlNifEnv *env, uint64_t pointer) {
  // We want to take full ownership of the stream, so we copy it
  // into our resource-managed memory and we disable the release
  // on the source, so that we are the ones responsible for
  // releasing the stream.
  auto stream_res = fine::make_resource<ArrowArrayStreamResource>();
  auto source = reinterpret_cast<struct ArrowArrayStream *>(pointer);
  memcpy(&stream_res->value, source, sizeof(struct ArrowArrayStream));
  source->release = nullptr;
  return fine::Ok(stream_res);
}
FINE_NIF(adbc_arrow_array_stream_from_pointer, 0);

fine::Term
adbc_arrow_array_stream_next(ErlNifEnv *env,
                             fine::ResourcePtr<ArrowArrayStreamResource> res) {
  struct ArrowArray array{};
  std::vector<ERL_NIF_TERM> out_terms;
  ERL_NIF_TERM error{};

  if (res->value.get_next == nullptr) {
    throw std::invalid_argument("invalid arrow array stream");
  }

  int code = res->value.get_next(&res->value, &array);
  if (code != 0) {
    const char *reason = res->value.get_last_error(&res->value);
    return fine::encode(
        env, fine::Error(fine::Term(fine::encode(
                 env, std::string_view(
                          reason ? reason
                                 : "unknown error: cannot get next record")))));
  }

  // if no error and the array is released, the stream has ended
  if (array.release == nullptr) {
    return fine::Term(kAtomEndOfSeries);
  }

  // only fetch schema once for the entire stream
  if (res->schema.release == nullptr) {
    code = res->value.get_schema(&res->value, &res->schema);
    if (code != 0) {
      const char *reason = res->value.get_last_error(&res->value);
      if (res->schema.release)
        res->schema.release(&res->schema);
      res->schema = {};
      if (array.release)
        array.release(&array);
      return fine::encode(
          env, fine::Error(fine::Term(fine::encode(
                   env, std::string_view(reason ? reason : "unknown error")))));
    }
  }

  code = arrow_schema_to_nif_term(env, &res->schema, &array, out_terms, error);
  if (array.release)
    array.release(&array);

  if (code != 0) {
    // error is already set in arrow_schema_to_nif_term
    // we don't need to release the schema in the res here
    // it will be released when the stream resource is GC'd
    return fine::encode(env, fine::Error(fine::Term(error)));
  }
  return fine::encode(env, fine::Ok(fine::Term(out_terms[0])));
}
FINE_NIF(adbc_arrow_array_stream_next, ERL_NIF_DIRTY_JOB_IO_BOUND);

fine::Ok<> adbc_arrow_array_stream_release(
    ErlNifEnv *env, fine::ResourcePtr<ArrowArrayStreamResource> res) {
  if (res->value.release) {
    res->value.release(&res->value);
    res->value.release = nullptr;
  }
  return fine::Ok<>();
}
FINE_NIF(adbc_arrow_array_stream_release, ERL_NIF_DIRTY_JOB_IO_BOUND);

fine::Term
adbc_column_materialize(ErlNifEnv *env,
                        fine::ResourcePtr<ArrowArrayStreamRecord> res) {
  if (res->schema.release == nullptr || res->values.release == nullptr) {
    throw std::invalid_argument("invalid record: missing schema or values");
  }

  std::vector<ERL_NIF_TERM> out_terms;
  constexpr int level = 0;
  ERL_NIF_TERM out_type;
  ERL_NIF_TERM out_metadata;
  ERL_NIF_TERM error{};
  if (arrow_array_to_nif_term(env, &res->schema, &res->values, level, out_terms,
                              out_type, out_metadata, error, false,
                              (void *)res.get()) != 0) {
    return fine::Term(error);
  }

  ERL_NIF_TERM ret = (out_terms.size() == 1) ? out_terms[0] : out_terms[1];
  return fine::encode(
      env, fine::Ok(fine::Term(enif_make_tuple2(
               env, ret, enif_make_int64(env, res->values.length)))));
}
FINE_NIF(adbc_column_materialize, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term adbc_ipc_system_endianness(ErlNifEnv *env) {
  if (ArrowIpcSystemEndianness() == NANOARROW_IPC_ENDIANNESS_BIG) {
    return fine::Term(kAtomBig);
  } else {
    return fine::Term(kAtomLittle);
  }
}
FINE_NIF(adbc_ipc_system_endianness, 0);

fine::Term adbc_ipc_load_stream_binary(ErlNifEnv *env, ErlNifBinary binary) {
  nanoarrow::UniqueBuffer input_buffer;

  ArrowErrorCode code =
      ArrowBufferAppend(input_buffer.get(), binary.data, binary.size);
  if (code != NANOARROW_OK) {
    return fine::encode(
        env, fine::Error(std::string(
                 "Failed to append binary data to Arrow IPC input buffer")));
  }

  struct ArrowIpcInputStream input;
  code = ArrowIpcInputStreamInitBuffer(&input, input_buffer.get());
  if (code != NANOARROW_OK) {
    return fine::encode(
        env, fine::Error(
                 std::string("Failed to initialize Arrow IPC array stream")));
  }

  auto stream_res = fine::make_resource<ArrowArrayStreamResource>();
  code = ArrowIpcArrayStreamReaderInit(&stream_res->value, &input, nullptr);
  if (code != NANOARROW_OK) {
    return fine::encode(
        env, fine::Error(std::string(
                 "Failed to initialize Arrow IPC array stream reader")));
  }

  return fine::encode(env, stream_res);
}
FINE_NIF(adbc_ipc_load_stream_binary, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::Term
adbc_ipc_dump_stream_ref(ErlNifEnv *env,
                         fine::ResourcePtr<ArrowArrayStreamResource> res) {
  if (res->value.release == nullptr) {
    return fine::encode(
        env, fine::Error(std::string("stream has already been consumed")));
  }

  struct ArrowError arrow_error{};
  nanoarrow::UniqueBuffer output;
  nanoarrow::ipc::UniqueOutputStream ostream;
  int code = ArrowIpcOutputStreamInitBuffer(ostream.get(), output.get());
  if (code != NANOARROW_OK) {
    return fine::encode(
        env, fine::Error(std::string("invalid Arrow IPC output stream")));
  }

  nanoarrow::ipc::UniqueWriter writer;
  code = ArrowIpcWriterInit(writer.get(), ostream.get());
  if (code != NANOARROW_OK) {
    return fine::encode(env,
                        fine::Error(std::string("invalid Arrow IPC writer")));
  }

  code =
      ArrowIpcWriterWriteArrayStream(writer.get(), &res->value, &arrow_error);

  if (res->value.release) {
    res->value.release(&res->value);
  }

  if (code != NANOARROW_OK) {
    return fine::encode(env, fine::Error(arrow_error_term(env, &arrow_error)));
  }

  ErlNifBinary binary;
  if (!enif_alloc_binary(output->size_bytes, &binary)) {
    return fine::encode(env, fine::Error(std::string("out of memory")));
  }

  memcpy(binary.data, output->data, output->size_bytes);
  ArrowIpcWriterReset(writer.get());
  return fine::encode(env,
                      fine::Ok(fine::Term(enif_make_binary(env, &binary))));
}
FINE_NIF(adbc_ipc_dump_stream_ref, ERL_NIF_DIRTY_JOB_CPU_BOUND);

fine::ResourcePtr<AdbcExecuteOnGCResource>
adbc_execute_on_gc_new(ErlNifEnv *env, ErlNifPid pid, std::string statement) {
  auto res = fine::make_resource<AdbcExecuteOnGCResource>();
  res->pid = pid;
  res->statement = std::move(statement);
  return res;
}
FINE_NIF(adbc_execute_on_gc_new, 0);

FINE_INIT("Elixir.Adbc.Nif");
