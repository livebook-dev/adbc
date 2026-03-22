#ifndef ERLANG_NIF_UTILS_HPP
#define ERLANG_NIF_UTILS_HPP

#pragma once

#include <erl_nif.h>
#include <stdarg.h>
#include <map>
#include <string>
#include <cstring>
#include <vector>
#include <cstdint>

#if defined(_WIN32) || defined(WIN32) || defined(__CYGWIN__) || defined(__MINGW32__) || defined(__BORLANDC__)
#define OS_WIN
#endif

namespace erlang {
namespace nif {
// Atoms

int get_atom(ErlNifEnv *env, ERL_NIF_TERM term, std::string &var);
ERL_NIF_TERM atom(ErlNifEnv *env, const char *msg);

// Helper for returning `{:error, msg}` from NIF.
ERL_NIF_TERM error(ErlNifEnv *env, const char *msg);
ERL_NIF_TERM error(ErlNifEnv *env, ERL_NIF_TERM term);

// Helper for returning `{:ok, term}` from NIF.
ERL_NIF_TERM ok(ErlNifEnv *env);

// Helper for returning `:ok` from NIF.
ERL_NIF_TERM ok(ErlNifEnv *env, ERL_NIF_TERM term);

template<typename T>
int make_f64_list_from_c_array(ErlNifEnv *env, size_t count, T *data, ERL_NIF_TERM &out) {
    if (count == 0) {
        out = enif_make_list_from_array(env, nullptr, 0);
        return 0;
    }

    ERL_NIF_TERM *terms = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * count);
    if (terms == nullptr) {
        return 1;
    }
    for (size_t i = 0; i < count; ++i) {
        terms[i] = enif_make_double(env, (double)(data[i]));
    }
    out = enif_make_list_from_array(env, terms, (unsigned) count);
    enif_free(terms);
    return 0;
}

template<typename T>
int make_i64_list_from_c_array(ErlNifEnv *env, size_t count, T *data, ERL_NIF_TERM &out) {
    if (count == 0) {
        out = enif_make_list_from_array(env, nullptr, 0);
        return 0;
    }

    ERL_NIF_TERM *terms = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * count);
    if (terms == nullptr) {
        return 1;
    }
    for (size_t i = 0; i < count; ++i) {
        terms[i] = enif_make_int64(env, (int64_t)(data[i]));
    }
    out = enif_make_list_from_array(env, terms, (unsigned) count);
    enif_free(terms);
    return 0;
}

template<typename T>
int make_u64_list_from_c_array(ErlNifEnv *env, size_t count, T *data, ERL_NIF_TERM &out) {
    if (count == 0) {
        out = enif_make_list_from_array(env, nullptr, 0);
        return 0;
    }

    ERL_NIF_TERM *terms = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * count);
    if (terms == nullptr) {
        return 1;
    }
    for (size_t i = 0; i < count; ++i) {
        terms[i] = enif_make_uint64(env, (uint64_t)(data[i]));
    }
    out = enif_make_list_from_array(env, terms, (unsigned) count);
    enif_free(terms);
    return 0;
}

template<typename T>
int make_i32_list_from_c_array(ErlNifEnv *env, size_t count, T *data, ERL_NIF_TERM &out) {
    if (count == 0) {
        out = enif_make_list_from_array(env, nullptr, 0);
        return 0;
    }

    ERL_NIF_TERM *terms = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * count);
    if (terms == nullptr) {
        return 1;
    }
    for (size_t i = 0; i < count; ++i) {
        terms[i] = enif_make_int(env, (int32_t)(data[i]));
    }
    out = enif_make_list_from_array(env, terms, (unsigned) count);
    enif_free(terms);
    return 0;
}

template<typename T>
int make_u32_list_from_c_array(ErlNifEnv *env, size_t count, T *data, ERL_NIF_TERM &out) {
    if (count == 0) {
        out = enif_make_list_from_array(env, nullptr, 0);
        return 0;
    }

    ERL_NIF_TERM *terms = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * count);
    if (terms == nullptr) {
        return 1;
    }
    for (size_t i = 0; i < count; ++i) {
        terms[i] = enif_make_uint(env, (uint32_t)(data[i]));
    }
    out = enif_make_list_from_array(env, terms, (unsigned) count);
    enif_free(terms);
    return 0;
}

// Numeric types

int get(ErlNifEnv *env, ERL_NIF_TERM term, int *var);

int get(ErlNifEnv *env, ERL_NIF_TERM term, unsigned int *var);

int get(ErlNifEnv *env, ERL_NIF_TERM term, long long *var);

int get(ErlNifEnv *env, ERL_NIF_TERM term, unsigned long long *var);

int get(ErlNifEnv *env, ERL_NIF_TERM term, long *var);

int get(ErlNifEnv *env, ERL_NIF_TERM term, unsigned long *var);

int get(ErlNifEnv *env, ERL_NIF_TERM term, double *var);

// Standard types

int get(ErlNifEnv *env, ERL_NIF_TERM term, std::string &var);
int get(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *var);

ERL_NIF_TERM make(ErlNifEnv *env, bool var);
ERL_NIF_TERM make(ErlNifEnv *env, long var);
ERL_NIF_TERM make(ErlNifEnv *env, int32_t var);
ERL_NIF_TERM make(ErlNifEnv *env, long long var);
ERL_NIF_TERM make(ErlNifEnv *env, uint32_t var);
ERL_NIF_TERM make(ErlNifEnv *env, unsigned long long var);
ERL_NIF_TERM make(ErlNifEnv *env, double var);
ERL_NIF_TERM make(ErlNifEnv *env, ErlNifBinary var);
ERL_NIF_TERM make(ErlNifEnv *env, std::string var);
ERL_NIF_TERM make(ErlNifEnv *env, const char *string);

int make(ErlNifEnv *env, bool var, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, long var, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, int var, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, double var, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, uint64_t var, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, ErlNifBinary var, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::string& var, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const char *string, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<uint8_t>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<uint16_t>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<uint32_t>& array, ERL_NIF_TERM &out);
#ifndef OS_WIN
int make(ErlNifEnv *env, const std::vector<unsigned long long>& array, ERL_NIF_TERM &out);
#endif
int make(ErlNifEnv *env, const std::vector<int8_t>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<int16_t>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<int32_t>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<long long>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<size_t>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<float>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<double>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<std::string>& array, ERL_NIF_TERM &out);
int make(ErlNifEnv *env, const std::vector<const std::string*>& array, ERL_NIF_TERM &out);

ERL_NIF_TERM make_binary(ErlNifEnv *env, const char *c_string);
ERL_NIF_TERM make_binary(ErlNifEnv *env, const char *c_string, size_t length);
ERL_NIF_TERM make_binary(ErlNifEnv *env, const std::string& string);

template <typename Key, typename Value>
int make(ErlNifEnv *env, const std::map<Key, Value>& map, ERL_NIF_TERM &out, bool atom_key) {
    bool failed = false;
    size_t size = map.size();
    
    if (size == 0) {
        out = enif_make_new_map(env);
        return 0;
    }

    ERL_NIF_TERM * keys = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * size);
    if (!keys) {
        return 1;
    }
    ERL_NIF_TERM * values = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * size);
    if (!values) {
        enif_free(keys);
        return 1;
    }

    size_t index = 0;
    for (const auto &p : map) {
        if (atom_key) {
            keys[index] = atom(env, p.first.c_str());
        } else {
            if (make(env, p.first, keys[index])) {
                failed = true;
                break;
            }
        }

        if (make(env, p.second, values[index])) {
            failed = true;
            break;
        }

        index++;
    }

    if (failed) {
        enif_free(keys);
        enif_free(values);
        return 1;
    }

    ERL_NIF_TERM map_out;
    if (!enif_make_map_from_arrays(env, keys, values, index, &map_out)) {
        return 1;
    }

    out = map_out;
    return 0;
}

template <typename Key, typename Value>
int make(ErlNifEnv *env, const std::vector<std::map<Key, Value>>& array, ERL_NIF_TERM &out, bool atom_key) {
    size_t count = array.size();
    if (count == 0) {
        out = enif_make_list_from_array(env, nullptr, 0);
        return 0;
    }

    ERL_NIF_TERM *terms = (ERL_NIF_TERM *)enif_alloc(sizeof(ERL_NIF_TERM) * count);
    if (terms == nullptr) {
        return 1;
    }
    for (size_t i = 0; i < count; ++i) {
        if (make(env, array[i], terms[i], atom_key)) {
            enif_free(terms);
            return 1;
        }
    }
    out = enif_make_list_from_array(env, terms, (unsigned)count);
    enif_free(terms);
    return 0;
}

// Check if :nil
int check_nil(ErlNifEnv *env, ERL_NIF_TERM term);

// Boolean

int get(ErlNifEnv *env, ERL_NIF_TERM term, bool *var);

// Containers

int get_tuple(ErlNifEnv *env, ERL_NIF_TERM tuple, std::vector<int64_t> &var);
int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<ErlNifBinary> &var);
int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<std::string> &var);
int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<int> &var);
int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<int64_t> &var);
int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<uint64_t> &var);
int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<uint32_t> &var);

}
}

#endif  // ERLANG_NIF_UTILS_HPP
