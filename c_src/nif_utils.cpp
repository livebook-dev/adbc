//
// Created by Cocoa on 14/06/2022.
//

#include "nif_utils.hpp"

namespace erlang {
namespace nif {

// Atoms

int get_atom(ErlNifEnv *env, ERL_NIF_TERM term, std::string &var) {
    unsigned atom_length;
    if (!enif_get_atom_length(env, term, &atom_length, ERL_NIF_LATIN1)) {
        return 0;
    }

    var.resize(atom_length + 1);

    if (!enif_get_atom(env, term, &(*(var.begin())), var.size(), ERL_NIF_LATIN1)) {
        return 0;
    }

    var.resize(atom_length);
    return 1;
}

ERL_NIF_TERM atom(ErlNifEnv *env, const char *msg) {
    ERL_NIF_TERM a;
    if (enif_make_existing_atom(env, msg, &a, ERL_NIF_LATIN1)) {
        return a;
    } else {
        return enif_make_atom(env, msg);
    }
}

// Helper for returning `{:error, msg}` from NIF.
ERL_NIF_TERM error(ErlNifEnv *env, const char *msg) {
    ERL_NIF_TERM error_atom = atom(env, "error");
    ERL_NIF_TERM reason;
    unsigned char *ptr;
    size_t len = strlen(msg);
    if ((ptr = enif_make_new_binary(env, len, &reason)) != nullptr) {
        strcpy((char *) ptr, msg);
        return enif_make_tuple2(env, error_atom, reason);
    } else {
        ERL_NIF_TERM msg_term = enif_make_string(env, msg, ERL_NIF_LATIN1);
        return enif_make_tuple2(env, error_atom, msg_term);
    }
}

ERL_NIF_TERM error(ErlNifEnv *env, ERL_NIF_TERM term) {
    ERL_NIF_TERM error_atom = atom(env, "error");
    return enif_make_tuple2(env, error_atom, term);
}

// Helper for returning `{:ok, term}` from NIF.
ERL_NIF_TERM ok(ErlNifEnv *env) {
    return atom(env, "ok");
}

// Helper for returning `:ok` from NIF.
ERL_NIF_TERM ok(ErlNifEnv *env, ERL_NIF_TERM term) {
    return enif_make_tuple2(env, ok(env), term);
}

// Boolean type

int get(ErlNifEnv *env, ERL_NIF_TERM term, bool *var) {
    std::string b;
    if (get_atom(env, term, b)) {
        if (b == "true") {
            *var = true;
            return 1;
        } else if (b == "false") {
            *var = false;
            return 1;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}

// Numeric types

int get(ErlNifEnv *env, ERL_NIF_TERM term, int *var) {
    return enif_get_int(env, term, var);
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, unsigned int *var) {
    return enif_get_uint(env, term, var);
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, long long *var) {
    return enif_get_int64(env, term, reinterpret_cast<ErlNifSInt64 *>(var));
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, unsigned long long *var) {
    return enif_get_uint64(env, term, reinterpret_cast<ErlNifUInt64 *>(var));
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, long *var) {
    return enif_get_int64(env, term, reinterpret_cast<ErlNifSInt64 *>(var));
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, unsigned long *var) {
    return enif_get_uint64(env, term, reinterpret_cast<ErlNifUInt64 *>(var));
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, double *var) {
    return enif_get_double(env, term, var);
}

// Standard types

int get(ErlNifEnv *env, ERL_NIF_TERM term, std::string &var) {
    unsigned len;
    int ret = enif_get_list_length(env, term, &len);

    if (!ret) {
        // iodata
        ErlNifBinary bin;
        ret = enif_inspect_iolist_as_binary(env, term, &bin);
        if (!ret) {
            return 0;
        }
        var = std::string((const char *)bin.data, bin.size);
        return ret;
    }

    // charlist
    var.resize(len + 1);
    ret = enif_get_string(env, term, &*(var.begin()), var.size(), ERL_NIF_LATIN1);

    if (ret > 0) {
        var.resize(ret - 1);
    } else if (ret == 0) {
        var.resize(0);
    }

    return ret;
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *var) {
    int code = enif_inspect_binary(env, term, var);
    if (!code) return enif_inspect_iolist_as_binary(env, term, var);
    return code;
}

ERL_NIF_TERM make(ErlNifEnv *env, bool var) {
    if (var) {
        return atom(env, "true");
    } else {
        return atom(env, "false");
    }
}

ERL_NIF_TERM make(ErlNifEnv *env, long var) {
    return enif_make_int64(env, var);
}

ERL_NIF_TERM make(ErlNifEnv *env, int32_t var) {
    return enif_make_int(env, var);
}

ERL_NIF_TERM make(ErlNifEnv *env, long long var) {
    return enif_make_int64(env, var);
}

ERL_NIF_TERM make(ErlNifEnv *env, uint32_t var) {
    return enif_make_uint(env, var);
}

ERL_NIF_TERM make(ErlNifEnv *env, unsigned long long var) {
    return enif_make_uint64(env, var);
}

ERL_NIF_TERM make(ErlNifEnv *env, double var) {
    return enif_make_double(env, var);
}

ERL_NIF_TERM make(ErlNifEnv *env, ErlNifBinary var) {
    return enif_make_binary(env, &var);
}

ERL_NIF_TERM make(ErlNifEnv *env, const std::string& var) {
    return enif_make_string(env, var.c_str(), ERL_NIF_LATIN1);
}

ERL_NIF_TERM make(ErlNifEnv *env, const char *string) {
    return enif_make_string(env, string, ERL_NIF_LATIN1);
}

int make(ErlNifEnv *env, bool var, ERL_NIF_TERM &out) {
    out = make(env, var);
    return 0;
}

int make(ErlNifEnv *env, long var, ERL_NIF_TERM &out) {
    out = make(env, var);
    return 0;
}

int make(ErlNifEnv *env, int var, ERL_NIF_TERM &out) {
    out = make(env, var);
    return 0;
}

int make(ErlNifEnv *env, uint64_t var, ERL_NIF_TERM &out) {
    out = make(env, (unsigned long long)var);
    return 0;
}

int make(ErlNifEnv *env, double var, ERL_NIF_TERM &out) {
    out = make(env, var);
    return 0;
}

int make(ErlNifEnv *env, ErlNifBinary var, ERL_NIF_TERM &out) {
    out = make(env, var);
    return 0;
}

int make(ErlNifEnv *env, const std::string& var, ERL_NIF_TERM &out) {
    out = make_binary(env, var);
    return 0;
}

int make(ErlNifEnv *env, const char *var, ERL_NIF_TERM &out) {
    out = make_binary(env, var);
    return 0;
}

int make(ErlNifEnv *env, const std::vector<uint8_t>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    uint8_t * data = (uint8_t *)array.data();
    return make_u32_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<uint16_t>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    uint16_t * data = (uint16_t *)array.data();
    return make_u32_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<uint32_t>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    uint32_t * data = (uint32_t *)array.data();
    return make_u32_list_from_c_array(env, count, data, out);
}

#ifndef OS_WIN
int make(ErlNifEnv *env, const std::vector<unsigned long long>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    uint64_t * data = (uint64_t *)array.data();
    return make_u64_list_from_c_array(env, count, data, out);
}
#endif

int make(ErlNifEnv *env, const std::vector<int8_t>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    int8_t * data = (int8_t *)array.data();
    return make_i32_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<int16_t>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    int16_t * data = (int16_t *)array.data();
    return make_i32_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<int32_t>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    int32_t * data = (int32_t *)array.data();
    return make_i32_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<long long>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    int64_t * data = (int64_t *)array.data();
    return make_i64_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<size_t>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    if (sizeof(size_t) == 8) {
        uint64_t * data = (uint64_t *)array.data();
        return make_u64_list_from_c_array(env, count, data, out);
    } else if (sizeof(size_t) == 4) {
        uint32_t * data = (uint32_t *)array.data();
        return make_u32_list_from_c_array(env, count, data, out);
    } else {
        // error
        return 1;
    }
}

int make(ErlNifEnv *env, const std::vector<float>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    float * data = (float *)array.data();
    return make_f64_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<double>& array, ERL_NIF_TERM &out) {
    size_t count = array.size();
    double * data = (double *)array.data();
    return make_f64_list_from_c_array(env, count, data, out);
}

int make(ErlNifEnv *env, const std::vector<std::string>& array, ERL_NIF_TERM &out) {
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
        terms[i] = make_binary(env, array[i]);
    }
    out = enif_make_list_from_array(env, terms, (unsigned)count);
    enif_free(terms);
    return 0;
}

int make(ErlNifEnv *env, const std::vector<const std::string*>& array, ERL_NIF_TERM &out) {
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
        terms[i] = make_binary(env, *array[i]);
    }
    out = enif_make_list_from_array(env, terms, (unsigned)count);
    enif_free(terms);
    return 0;
}

ERL_NIF_TERM make_binary(ErlNifEnv *env, const char *c_string) {
    ERL_NIF_TERM binary_str;
    unsigned char *ptr;
    size_t len = strlen(c_string);
    if ((ptr = enif_make_new_binary(env, len, &binary_str)) != nullptr) {
        memcpy((char *)ptr, c_string, len);
        return binary_str;
    } else {
        fprintf(stderr, "internal error: cannot allocate memory for binary string\r\n");
        return atom(env, "error");
    }
}

ERL_NIF_TERM make_binary(ErlNifEnv *env, const char *c_string, size_t length) {
    ERL_NIF_TERM binary_str;
    unsigned char *ptr;
    if ((ptr = enif_make_new_binary(env, length, &binary_str)) != nullptr) {
        memcpy((char *)ptr, c_string, length);
        return binary_str;
    } else {
        fprintf(stderr, "internal error: cannot allocate memory for binary string\r\n");
        return atom(env, "error");
    }
}

ERL_NIF_TERM make_binary(ErlNifEnv *env, const std::string& string) {
    ERL_NIF_TERM binary_str;
    unsigned char *ptr;
    size_t len = string.size();
    if ((ptr = enif_make_new_binary(env, len, &binary_str)) != nullptr) {
        memcpy((char *)ptr, string.c_str(), len);
        return binary_str;
    } else {
        fprintf(stderr, "internal error: cannot allocate memory for binary string\r\n");
        return atom(env, "error");
    }
}

// Check if :nil
int check_nil(ErlNifEnv *env, ERL_NIF_TERM term) {
    std::string atom_str;
    if (get_atom(env, term, atom_str) && atom_str == "nil") {
        return true;
    }
    return false;
}

// Containers

int get_tuple(ErlNifEnv *env, ERL_NIF_TERM tuple, std::vector<int64_t> &var) {
    const ERL_NIF_TERM *terms;
    int length;
    if (!enif_get_tuple(env, tuple, &length, &terms)) {
        return 0;
    }

    var.reserve(length);

    for (int i = 0; i < length; i++) {
        int data;
        if (!get(env, terms[i], &data)) {
            return 0;
        }

        var.push_back(data);
    }
    return 1;
}

int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<ErlNifBinary> &var) {
    unsigned int length;
    if (!enif_get_list_length(env, list, &length)) {
        return 0;
    }

    var.reserve(length);
    ERL_NIF_TERM head, tail;

    while (enif_get_list_cell(env, list, &head, &tail)) {
        ErlNifBinary elem;
        if (!enif_inspect_iolist_as_binary(env, head, &elem)) {
            return 0;
        }

        var.push_back(elem);
        list = tail;
    }
    return 1;
}

int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<std::string> &var) {
    unsigned int length;
    if (!enif_get_list_length(env, list, &length)) {
        return 0;
    }

    var.reserve(length);
    ERL_NIF_TERM head, tail;

    while (enif_get_list_cell(env, list, &head, &tail)) {
        std::string elem;
        if (!get_atom(env, head, elem)) {
            return 0;
        }

        var.push_back(elem);
        list = tail;
    }

    return 1;
}

int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<int> &var) {
    unsigned int length;
    if (!enif_get_list_length(env, list, &length)) {
        return 0;
    }

    var.reserve(length);
    ERL_NIF_TERM head, tail;

    while (enif_get_list_cell(env, list, &head, &tail)) {
        int elem;
        if (!get(env, head, &elem)) {
            return 0;
        }

        var.push_back(elem);
        list = tail;
    }

    return 1;
}

int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<int64_t> &var) {
    unsigned int length;
    if (!enif_get_list_length(env, list, &length)) {
        return 0;
    }

    var.reserve(length);
    ERL_NIF_TERM head, tail;

    while (enif_get_list_cell(env, list, &head, &tail)) {
        int64_t elem;
        if (!get(env, head, &elem)) {
            return 0;
        }

        var.push_back(elem);
        list = tail;
    }
    return 1;
}

int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<uint64_t> &var) {
    unsigned int length;
    if (!enif_get_list_length(env, list, &length)) {
        return 0;
    }

    var.reserve(length);
    ERL_NIF_TERM head, tail;

    while (enif_get_list_cell(env, list, &head, &tail)) {
        uint64_t elem;
        if (!get(env, head, &elem)) {
            return 0;
        }

        var.push_back(elem);
        list = tail;
    }
    return 1;
}

int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<uint32_t> &var) {
    unsigned int length;
    if (!enif_get_list_length(env, list, &length)) {
        return 0;
    }

    var.reserve(length);
    ERL_NIF_TERM head, tail;

    while (enif_get_list_cell(env, list, &head, &tail)) {
        uint32_t elem;
        if (!get(env, head, &elem)) {
            return 0;
        }

        var.push_back(elem);
        list = tail;
    }
    return 1;
}

}
}
