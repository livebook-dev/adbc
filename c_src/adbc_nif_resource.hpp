#ifndef ADBC_NIF_RESOURCE_HPP
#define ADBC_NIF_RESOURCE_HPP

#include <arrow-adbc/adbc.h>
#include <erl_nif.h>
#include <type_traits>

#include "adbc_arrow_array_stream_record.hpp"
#include "nif_utils.hpp"

// Only for debugging:
#include <cstdio>

template <typename...> using void_t = void;

// Check for the existence of member variable 'release' using SFINAE
template <typename T, typename = void>
struct release_guard : std::false_type {};

template <typename T>
struct release_guard<T, typename std::enable_if<std::is_same<
                            decltype(T::release), void (*)(T *)>::value>::type>
    : std::true_type {};

/// A NifRes<T> wraps a `T` to allow it to be shared between C++ and Erlang
/// while managing its lifetime properly.
///
/// Because the in-memory representation of a `*NifRes<T>` is the same as a
/// `*T`, the result from `my_nif_res->get_resource()` can be passed to a NIF
/// written in other languages as well (as long as they know the memory
/// representation of T).
///
/// Lifetime is managed automatically by:
/// - Returning an owned pointer from `allocate_resource` and `clone_ref`.
/// Behind the scenes, these calls manipulate Erlang's refcount of the resource
/// object.
/// - Whenever one of these owned pointers leaves the scope, the refcount is
/// decremented.
/// - Separately, a `destruct_resource` callback is provided to Erlang which
/// will be called by the GC when there are no references (from either Erlang or
/// C++ side) remaining.
template <typename T> struct NifRes {
  using val_type_p = T *;
  using val_type = T;
  using res_type = NifRes<T>;

  val_type val;

  // only used when T = struct
  void *private_data = nullptr;

  static ErlNifResourceType *type;

  /// Creates a new NifRes<T> using `enif_alloc_resource`, returning it as an
  /// owned pointer. When this owned pointer leaves the scope,
  /// `enif_release_resource` is automatically called.
  static auto allocate_resource(ErlNifEnv *env, ERL_NIF_TERM &error)
      -> res_type * {
    auto res = static_cast<res_type *>(
        enif_alloc_resource(res_type::type, sizeof(res_type)));
    if (res == nullptr) {
      error = erlang::nif::error(env, "cannot allocate Nif resource\n");
      return res;
    }
    memset(&res->val, 0, sizeof(val_type));
    res->private_data = nullptr;
    return res;
  }

  /// Given a `term` that should be a NifRes<T>,
  /// Obtain a pointer to the contained `val`
  /// which is guaranteed to be valid for at least the lifetime of `env`.
  ///
  /// In the case something which is not a NifRes<T> is passed,
  /// `nullptr` is returned and the output-parameter `error` filled.
  static res_type *get_resource(ErlNifEnv *env, ERL_NIF_TERM term,
                                ERL_NIF_TERM &error) {
    res_type *self_res = nullptr;
    if (!enif_get_resource(env, term, res_type::type,
                           reinterpret_cast<void **>(&self_res)) ||
        self_res == nullptr) {
      error = erlang::nif::error(env, "cannot access Nif resource");
    }

    return self_res;
  }

  /// Creates another reference to the same underlying NifRes to be used in
  /// Erlang. (uses `enif_make_resource`)
  ERL_NIF_TERM make_resource(ErlNifEnv *env) {
    return enif_make_resource(env, this);
  }

  // Called whenever a _single_ reference to the resource goes out of scope.
  // Decrements the reference count on the C++ side.
  ~NifRes() {
    enif_release_resource(this);
    val->~T();
  }
};

static void destruct_adbc_database_resource(ErlNifEnv *env, void *args) {
  auto res = (NifRes<struct AdbcDatabase> *)args;
  struct AdbcError adbc_error{};
  AdbcDatabaseRelease(&res->val, &adbc_error);
}

static void destruct_adbc_connection_resource(ErlNifEnv *env, void *args) {
  auto res = (NifRes<struct AdbcConnection> *)args;
  struct AdbcError adbc_error{};
  if (res->private_data != nullptr)
    enif_release_resource(&res->private_data);
  AdbcConnectionRelease(&res->val, &adbc_error);
}

static void destruct_adbc_statement_resource(ErlNifEnv *env, void *args) {
  auto res = (NifRes<struct AdbcStatement> *)args;
  struct AdbcError adbc_error{};
  if (res->private_data != nullptr)
    enif_release_resource(&res->private_data);
  AdbcStatementRelease(&res->val, &adbc_error);
}

static void destruct_adbc_error(ErlNifEnv *env, void *args) {
  auto res = (NifRes<struct AdbcError> *)args;
  if (res->val.release) {
    res->val.release(&res->val);
  }
}

static void destruct_adbc_arrow_array_stream(ErlNifEnv *env, void *args) {
  auto res = (NifRes<struct AdbcStatement> *)args;
  if (res->private_data) {
    auto schema = (struct ArrowSchema *)res->private_data;
    if (schema->release) {
      schema->release(schema);
    }
    enif_free(schema);
    res->private_data = nullptr;
  }
}

struct AdbcExecuteOnGC {
  ErlNifPid pid;
  std::string statement;
};

static void destruct_adbc_execute_on_gc(ErlNifEnv *env, void *args) {
  auto res = (NifRes<struct AdbcExecuteOnGC> *)args;
  ErlNifEnv *msg_env = enif_alloc_env();
  if (msg_env) {
    ERL_NIF_TERM statement_term =
        erlang::nif::make_binary(msg_env, res->val.statement);
    ERL_NIF_TERM msg = enif_make_tuple2(
        msg_env, erlang::nif::atom(msg_env, "execute_on_gc"), statement_term);
    enif_send(NULL, &res->val.pid, msg_env, msg);
    enif_free_env(msg_env);
  }
}

static void destruct_arrow_array_stream_record(ErlNifEnv *env, void *args) {
  auto res = (NifRes<struct ArrowArrayStreamRecord> *)args;
  if (res->val.schema) {
    if (res->val.schema->release) {
      res->val.schema->release(res->val.schema);
      res->val.schema->release = nullptr;
    }
    enif_free(res->val.schema);
    res->val.schema = nullptr;
  }

  if (res->val.values) {
    if (res->val.values->release) {
      res->val.values->release(res->val.values);
      res->val.values->release = nullptr;
    }
    enif_free(res->val.values);
    res->val.values = nullptr;
  }
}

#endif /* ADBC_NIF_RESOURCE_HPP */
