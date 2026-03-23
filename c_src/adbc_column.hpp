#ifndef ADBC_COLUMN_HPP
#pragma once

#include <time.h>
#include <cstdbool>
#include <cstdint>
#include <functional>
#include <type_traits>
#include <optional>
#include <arrow-adbc/adbc.h>
#include <erl_nif.h>
#include <nanoarrow/nanoarrow.hpp>
#include "adbc_consts.h"
#include "nif_utils.hpp"

struct AdbcColumnType {
    int valid = 0;

    enum ArrowType arrow_type;

    // only valid if arrow_type is one of
    // - NANOARROW_TYPE_TIME32
    // - NANOARROW_TYPE_TIME64
    // - NANOARROW_TYPE_DURATION
    // - NANOARROW_TYPE_TIMESTAMP
    enum ArrowTimeUnit time_unit;

    // only valid if arrow_type is NANOARROW_TYPE_TIMESTAMP
    std::string timezone;

    // only valid if arrow_type is NANOARROW_TYPE_FIXED_SIZE_*
    // if the value is `-1`, it means we need to infer the size from the data
    int32_t fixed_size;

    // only valid if arrow_type is NANOARROW_TYPE_DECIMAL128 or NANOARROW_TYPE_DECIMAL256
    int bits = 0;
    int precision = 0;
    int scale = 0;
};

struct AdbcColumnNifTerm {
    int is_nil;
    unsigned n_items;
    ERL_NIF_TERM struct_name_term, name_term, type_term, metadata_term, data_term;
    static int from_term(ErlNifEnv *env, ERL_NIF_TERM adbc_column, bool allow_nil, AdbcColumnNifTerm *out);
};

struct AdbcColumnType adbc_column_type_to_nanoarrow_type(ErlNifEnv *env, ERL_NIF_TERM type_term);
int adbc_column_to_adbc_field(ErlNifEnv *env, ERL_NIF_TERM adbc_column, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out, unsigned *n_items);
int adbc_column_to_adbc_field(ErlNifEnv *env, struct AdbcColumnNifTerm * column, bool allow_nil, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out);
int must_be_adbc_column(ErlNifEnv *env,
    ERL_NIF_TERM adbc_column,
    ERL_NIF_TERM &struct_name_term,
    ERL_NIF_TERM &name_term,
    ERL_NIF_TERM &type_term,
    ERL_NIF_TERM &metadata_term,
    ERL_NIF_TERM &data_term,
    unsigned *n_items);

int AdbcColumnNifTerm::from_term(ErlNifEnv *env, ERL_NIF_TERM adbc_column, bool allow_nil, AdbcColumnNifTerm *out) {
    if (enif_is_identical(adbc_column, kAtomNil)) {
        if (allow_nil) {
            if (out) {
                out->is_nil = 1;
            }
            return 0;
        } else {
            return 1;
        }
    }

    ERL_NIF_TERM struct_name_term, name_term, type_term, metadata_term, data_term;
    unsigned n_items = 0;
    int ret = must_be_adbc_column(env, adbc_column, struct_name_term, name_term, type_term, metadata_term, data_term, &n_items);
    if (ret != 0) {
        return ret;
    }

    if (out) {
        out->is_nil = 0;
        out->n_items = n_items;
        out->struct_name_term = struct_name_term;
        out->name_term = name_term;
        out->type_term = type_term;
        out->metadata_term = metadata_term;
        out->data_term = data_term;
    }

    return 0;
}

ERL_NIF_TERM make_adbc_field(ErlNifEnv *env, ERL_NIF_TERM name_term, ERL_NIF_TERM type_term, ERL_NIF_TERM metadata) {
    std::vector<ERL_NIF_TERM> keys = {
        kAtomStructKey,
        kAtomNameKey,
        kAtomTypeKey,
        kAtomMetadataKey,
    };
    std::vector<ERL_NIF_TERM> values = {
        kAtomAdbcFieldModule,
        name_term,
        type_term,
        metadata,
    };

    ERL_NIF_TERM adbc_field;
    enif_make_map_from_arrays(env, keys.data(), values.data(), (unsigned)values.size(), &adbc_field);
    return adbc_field;
}

ERL_NIF_TERM make_adbc_field(ErlNifEnv *env, struct ArrowSchema * schema, ERL_NIF_TERM type_term, ERL_NIF_TERM metadata) {
    ERL_NIF_TERM name_term = erlang::nif::make_binary(env, schema->name == nullptr ? "" : schema->name);
    return make_adbc_field(env, name_term, type_term, metadata);
}

ERL_NIF_TERM make_adbc_column(ErlNifEnv *env, struct ArrowSchema * schema, ERL_NIF_TERM type_term, ERL_NIF_TERM metadata, std::optional<ERL_NIF_TERM> data_ref = std::nullopt) {
    ERL_NIF_TERM field_term = make_adbc_field(env, schema, type_term, metadata);
    ERL_NIF_TERM data_ref_list = data_ref ? data_ref.value() : kAtomNil;

    std::vector<ERL_NIF_TERM> keys = {
        kAtomStructKey,
        kAtomFieldKey,
        kAtomDataKey,
        kAtomSizeKey,
    };
    std::vector<ERL_NIF_TERM> values = {
        kAtomAdbcColumnModule,
        field_term,
        data_ref_list,
        kAtomNil,
    };

    ERL_NIF_TERM adbc_column;
    enif_make_map_from_arrays(env, keys.data(), values.data(), (unsigned)values.size(), &adbc_column);
    return adbc_column;
}

ERL_NIF_TERM make_adbc_column(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * array, ERL_NIF_TERM name_term, ERL_NIF_TERM type_term, ERL_NIF_TERM metadata, ERL_NIF_TERM data) {
    ERL_NIF_TERM field_term = make_adbc_field(env, name_term, type_term, metadata);

    std::vector<ERL_NIF_TERM> keys = {
        kAtomStructKey,
        kAtomFieldKey,
        kAtomDataKey,
        kAtomSizeKey,
    };

    std::vector<ERL_NIF_TERM> values = {
        kAtomAdbcColumnModule,
        field_term,
        data,
        kAtomNil,
    };

    ERL_NIF_TERM adbc_column;
    enif_make_map_from_arrays(env, keys.data(), values.data(), (unsigned)values.size(), &adbc_column);
    return adbc_column;
}

ERL_NIF_TERM make_adbc_column(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, ERL_NIF_TERM name_term, const char * type, ERL_NIF_TERM metadata, ERL_NIF_TERM data) {
    ERL_NIF_TERM type_term = erlang::nif::make_binary(env, type);
    return make_adbc_column(env, schema, values, name_term, type_term, metadata, data);
}

ERL_NIF_TERM make_adbc_column(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, const char * name, const char * type, ERL_NIF_TERM metadata, ERL_NIF_TERM data) {
    ERL_NIF_TERM name_term = erlang::nif::make_binary(env, name == nullptr ? "" : name);
    return make_adbc_column(env, schema, values, name_term, type, metadata, data);
}

int do_get_buffer_datas(ErlNifEnv *env, ERL_NIF_TERM batches_list, size_t element_bytes, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out);

template <typename T>
int do_get_list_integer(ErlNifEnv *env, ERL_NIF_TERM list, ArrowType nanoarrow_type, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, nanoarrow_type));
    return do_get_buffer_datas(env, list, sizeof(T), array_out, schema_out, error_out);
}


// Copy a validity bitmap into an Arrow array, handling arbitrary bit_offset.
// When bit_offset is byte-aligned, uses bulk memcpy. Otherwise falls back to per-bit copy.
static int copy_validity_bitmap(const uint8_t* src, int bit_offset, size_t count,
                                struct ArrowArray* write_array) {
    struct ArrowBuffer* validity_buffer = ArrowArrayBuffer(write_array, 0);
    size_t validity_bytes = (count + 7) / 8;
    NANOARROW_RETURN_NOT_OK(ArrowBufferReserve(validity_buffer, validity_bytes));

    if (bit_offset % 8 == 0) {
        size_t bitmap_start = bit_offset / 8;
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(validity_buffer, src + bitmap_start, validity_bytes));
        write_array->null_count = count - ArrowBitCountSet(src + bitmap_start, 0, count);
    } else {
        size_t src_bit = bit_offset;
        size_t valid_count = 0;
        for (size_t dst_byte = 0; dst_byte < validity_bytes; dst_byte++) {
            uint8_t byte = 0;
            size_t bits_in_byte = (dst_byte == validity_bytes - 1 && count % 8 != 0) ? count % 8 : 8;
            for (size_t b = 0; b < bits_in_byte; b++) {
                if (ArrowBitGet(src, src_bit)) {
                    byte |= (uint8_t)(1 << b);
                    valid_count++;
                }
                src_bit++;
            }
            NANOARROW_RETURN_NOT_OK(ArrowBufferAppendInt8(validity_buffer, byte));
        }
        write_array->null_count = count - valid_count;
    }
    return 0;
}

// Append raw bytes directly to the Arrow data buffer (buffer index 1).
// Used when the Elixir side has already encoded data in Arrow's native layout.
// Parse an %Adbc.BufferData{} struct and bulk-copy data and validity buffers into the Arrow array.
int get_buffer_data(ErlNifEnv *env, ERL_NIF_TERM data_term, struct ArrowArray* write_array, size_t element_bytes) {
    ERL_NIF_TERM data_field, validity_field, bit_offset_field;
    if (!enif_get_map_value(env, data_term, kAtomDataKey, &data_field)) return 1;
    if (!enif_get_map_value(env, data_term, kAtomValidity, &validity_field)) return 1;
    if (!enif_get_map_value(env, data_term, kAtomBitOffsetKey, &bit_offset_field)) return 1;

    ErlNifBinary binary;
    if (!enif_inspect_binary(env, data_field, &binary)) {
        return 1;
    }

    if (binary.size % element_bytes != 0) {
        return 1;
    }
    size_t count = binary.size / element_bytes;

    bool has_validity = !enif_is_identical(validity_field, kAtomNil);
    ErlNifBinary validity_bin;
    int bit_offset = 0;
    if (has_validity) {
        if (!enif_inspect_binary(env, validity_field, &validity_bin)) {
            return 1;
        }
    }
    if (!enif_get_int(env, bit_offset_field, &bit_offset)) {
        return 1;
    }

    NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 1), binary.data, binary.size));

    if (has_validity) {
        NANOARROW_RETURN_NOT_OK(copy_validity_bitmap(validity_bin.data, bit_offset, count, write_array));
    }

    write_array->length = count;
    return 0;
}

// Generic ingest for types that store data as %Adbc.BufferData{} structs.
// The schema must already be set up on schema_out before calling this.
int do_get_buffer_datas(ErlNifEnv *env, ERL_NIF_TERM data_term, size_t element_bytes, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    nanoarrow::UniqueArray tmp;
    struct ArrowArray* write_array = tmp.get();
    NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(write_array, schema_out, error_out));
    NANOARROW_RETURN_NOT_OK(ArrowArrayStartAppending(write_array));

    int ret = get_buffer_data(env, data_term, write_array, element_bytes);
    if (ret != 0) return ret;

    NANOARROW_RETURN_NOT_OK(ArrowArrayFinishBuildingDefault(tmp.get(), error_out));
    ArrowArrayMove(tmp.get(), array_out);
    return 0;
}

int do_get_list_decimal(ErlNifEnv *env, ERL_NIF_TERM batches_list, ArrowType nanoarrow_type, int32_t bitwidth, int32_t precision, int32_t scale, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeDecimal(schema_out, nanoarrow_type, precision, scale));
    return do_get_buffer_datas(env, batches_list, bitwidth / 8, array_out, schema_out, error_out);
}

int do_get_dictionary(ErlNifEnv *env, ERL_NIF_TERM type_term, ERL_NIF_TERM batches_list, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    // type_term is {:dictionary, key_field, value_field}
    int arity;
    const ERL_NIF_TERM *tuple_elems;
    if (!enif_get_tuple(env, type_term, &arity, &tuple_elems) || arity != 3) {
        snprintf(error_out->message, sizeof(error_out->message), "Expected dictionary type to be {:dictionary, key_field, value_field}");
        return 1;
    }
    ERL_NIF_TERM key_field_map = tuple_elems[1];
    ERL_NIF_TERM value_field_map = tuple_elems[2];

    // data is a %{key: data, value: data} map
    ERL_NIF_TERM key_data, value_data_term;
    if (!enif_get_map_value(env, batches_list, kAtomKey, &key_data)) {
        return kErrorBufferGetMapValue;
    }
    if (!enif_get_map_value(env, batches_list, kAtomValue, &value_data_term)) {
        return kErrorBufferGetMapValue;
    }
    struct AdbcColumnNifTerm keys;
    keys.is_nil = 0;
    if (!enif_get_map_value(env, key_field_map, kAtomTypeKey, &keys.type_term)) return kErrorBufferGetMapValue;
    if (!enif_get_map_value(env, key_field_map, kAtomNameKey, &keys.name_term)) return kErrorBufferGetMapValue;
    if (!enif_get_map_value(env, key_field_map, kAtomMetadataKey, &keys.metadata_term)) return kErrorBufferGetMapValue;
    keys.data_term = key_data;
    keys.struct_name_term = kAtomAdbcFieldModule;
    keys.n_items = 0;

    struct AdbcColumnNifTerm values;
    values.is_nil = 0;
    if (!enif_get_map_value(env, value_field_map, kAtomTypeKey, &values.type_term)) return kErrorBufferGetMapValue;
    if (!enif_get_map_value(env, value_field_map, kAtomNameKey, &values.name_term)) return kErrorBufferGetMapValue;
    if (!enif_get_map_value(env, value_field_map, kAtomMetadataKey, &values.metadata_term)) return kErrorBufferGetMapValue;
    values.data_term = value_data_term;
    values.struct_name_term = kAtomAdbcFieldModule;
    values.n_items = 0;

    int ret = adbc_column_to_adbc_field(env, &keys, true, array_out, schema_out, error_out);
    if (ret != 0) {
        goto failed;
    }

    NANOARROW_RETURN_NOT_OK(ArrowSchemaAllocateDictionary(schema_out));
    NANOARROW_RETURN_NOT_OK(ArrowArrayAllocateDictionary(array_out));

    ret = adbc_column_to_adbc_field(env, &values, true, array_out->dictionary, schema_out->dictionary, error_out);
    if (ret == 0) return ret;

failed:
    if (schema_out->release != nullptr) {
        schema_out->release(schema_out);
        schema_out->release = nullptr;
    }
    if (array_out->release != nullptr) {
        array_out->release(array_out);
        array_out->release = nullptr;
    }
    return ret;
}

int do_get_list_string(ErlNifEnv *env, ERL_NIF_TERM list, ArrowType nanoarrow_type, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, nanoarrow_type));

    size_t offset_size = (nanoarrow_type == NANOARROW_TYPE_LARGE_STRING || nanoarrow_type == NANOARROW_TYPE_LARGE_BINARY) ? 8 : 4;

    nanoarrow::UniqueArray tmp;
    struct ArrowArray* write_array = tmp.get();
    NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(write_array, schema_out, error_out));

    // list is an %Adbc.BinaryData{offsets, data, validity | nil, offset}
    // Buffers: 0 = validity, 1 = offsets, 2 = data
    {
        ERL_NIF_TERM offsets_term, data_term, validity_term, offset_term;
        if (!enif_get_map_value(env, list, kAtomOffsets, &offsets_term)) return 1;
        if (!enif_get_map_value(env, list, kAtomDataKey, &data_term)) return 1;
        if (!enif_get_map_value(env, list, kAtomValidity, &validity_term)) return 1;
        if (!enif_get_map_value(env, list, kAtomBitOffsetKey, &offset_term)) return 1;

        ErlNifBinary offsets_bin, data_bin;
        if (!enif_inspect_binary(env, offsets_term, &offsets_bin)) return 1;
        if (!enif_inspect_binary(env, data_term, &data_bin)) return 1;
        if (offsets_bin.size < offset_size) return 1;
        size_t count = (offsets_bin.size / offset_size) - 1;

        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 1), offsets_bin.data, offsets_bin.size));
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 2), data_bin.data, data_bin.size));

        bool has_validity = !enif_is_identical(validity_term, kAtomNil);
        if (has_validity) {
            ErlNifBinary validity_bin;
            int bit_offset = 0;
            if (!enif_inspect_binary(env, validity_term, &validity_bin)) return 1;
            if (!enif_get_int(env, offset_term, &bit_offset)) return 1;
            NANOARROW_RETURN_NOT_OK(copy_validity_bitmap(validity_bin.data, bit_offset, count, write_array));
        }

        write_array->length = count;
    }
    NANOARROW_RETURN_NOT_OK(ArrowArrayFinishBuildingDefault(tmp.get(), error_out));
    ArrowArrayMove(tmp.get(), array_out);
    return 0;
}

int do_get_list_boolean(ErlNifEnv *env, ERL_NIF_TERM data_term, ArrowType nanoarrow_type, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, nanoarrow_type));

    // %Adbc.BufferData{data: binary, validity: binary | nil, bit_offset: int, size: int}
    ERL_NIF_TERM data_field, validity_field, bit_offset_field, size_field;
    if (!enif_get_map_value(env, data_term, kAtomDataKey, &data_field)) return 1;
    if (!enif_get_map_value(env, data_term, kAtomValidity, &validity_field)) return 1;
    if (!enif_get_map_value(env, data_term, kAtomBitOffsetKey, &bit_offset_field)) return 1;
    if (!enif_get_map_value(env, data_term, kAtomSizeKey, &size_field)) return 1;

    ErlNifBinary data_bin;
    if (!enif_inspect_binary(env, data_field, &data_bin)) return 1;

    int bit_offset = 0;
    if (!enif_get_int(env, bit_offset_field, &bit_offset)) return 1;

    long count = 0;
    if (!enif_get_long(env, size_field, &count)) return 1;

    nanoarrow::UniqueArray tmp;
    struct ArrowArray* write_array = tmp.get();
    NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(write_array, schema_out, error_out));

    // Copy data bitmap (buffer 1)
    NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 1), data_bin.data, data_bin.size));

    bool has_validity = !enif_is_identical(validity_field, kAtomNil);
    if (has_validity) {
        ErlNifBinary validity_bin;
        if (!enif_inspect_binary(env, validity_field, &validity_bin)) return 1;
        NANOARROW_RETURN_NOT_OK(copy_validity_bitmap(validity_bin.data, bit_offset, count, write_array));
    }

    write_array->length = count;
    NANOARROW_RETURN_NOT_OK(ArrowArrayFinishBuildingDefault(tmp.get(), error_out));
    ArrowArrayMove(tmp.get(), array_out);
    return 0;
}

int do_get_list_date(ErlNifEnv *env, ERL_NIF_TERM list, ArrowType nanoarrow_type, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, nanoarrow_type));
    return do_get_buffer_datas(env, list, (nanoarrow_type == NANOARROW_TYPE_DATE32) ? 4 : 8, array_out, schema_out, error_out);
}

int do_get_list_time(ErlNifEnv *env, ERL_NIF_TERM list, ArrowType nanoarrow_type, enum ArrowTimeUnit time_unit, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeDateTime(schema_out, nanoarrow_type, time_unit, NULL));
    return do_get_buffer_datas(env, list, (nanoarrow_type == NANOARROW_TYPE_TIME32) ? 4 : 8, array_out, schema_out, error_out);
}

int do_get_list_timestamp(ErlNifEnv *env, ERL_NIF_TERM list, ArrowType nanoarrow_type, enum ArrowTimeUnit time_unit, const char * timezone, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeDateTime(schema_out, nanoarrow_type, time_unit, timezone));
    return do_get_buffer_datas(env, list, 8, array_out, schema_out, error_out);
}

int do_get_list_duration(ErlNifEnv *env, ERL_NIF_TERM list, ArrowType nanoarrow_type, enum ArrowTimeUnit time_unit, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeDateTime(schema_out, nanoarrow_type, time_unit, NULL));
    return do_get_buffer_datas(env, list, 8, array_out, schema_out, error_out);
}

int do_get_list_interval(ErlNifEnv *env, ERL_NIF_TERM list, ArrowType nanoarrow_type, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, nanoarrow_type));
    size_t element_bytes = (nanoarrow_type == NANOARROW_TYPE_INTERVAL_MONTHS) ? 4 :
                           (nanoarrow_type == NANOARROW_TYPE_INTERVAL_DAY_TIME) ? 8 : 16;
    return do_get_buffer_datas(env, list, element_bytes, array_out, schema_out, error_out);
}

int do_get_list(ErlNifEnv *env, ERL_NIF_TERM parent_type_term, ERL_NIF_TERM list, struct AdbcColumnType * column_type, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    if (column_type == nullptr) {
        enif_snprintf(error_out->message, sizeof(error_out->message), "internal error: column_type is null in do_get_list:%d", __LINE__);
        return kErrorInternalError;
    }

    if (column_type->arrow_type == NANOARROW_TYPE_FIXED_SIZE_LIST) {
        NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeFixedSize(schema_out, column_type->arrow_type, column_type->fixed_size));
    } else {
        NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, column_type->arrow_type));
    }

    // Extract inner field from parent type: {:list, inner_field} or {:large_list, inner_field}
    // or {:fixed_size_list, inner_field, size}
    ERL_NIF_TERM inner_type_term = kAtomNil;
    {
        int arity;
        const ERL_NIF_TERM *tuple_elems;
        if (enif_get_tuple(env, parent_type_term, &arity, &tuple_elems) && arity >= 2) {
            ERL_NIF_TERM inner_field_term = tuple_elems[1];
            if (enif_is_map(env, inner_field_term)) {
                enif_get_map_value(env, inner_field_term, kAtomTypeKey, &inner_type_term);
            }
        }
    }

    if (enif_is_identical(inner_type_term, kAtomNil)) {
        snprintf(error_out->message, sizeof(error_out->message),
            "list type must be {:list, %%Adbc.Field{}} with inner type info");
        return 1;
    }

    // data is %{offsets: binary, validity: binary|nil, values: data, offset: int}
    {
        if (!enif_is_map(env, list)) {
            snprintf(error_out->message, sizeof(error_out->message),
                "Expected list data to be a map with offsets, validity, values, and offset");
            return 1;
        }

        ERL_NIF_TERM offsets_term, validity_term, values_term, offset_term;
        if (!enif_get_map_value(env, list, kAtomOffsets, &offsets_term) ||
            !enif_get_map_value(env, list, kAtomValidity, &validity_term) ||
            !enif_get_map_value(env, list, kAtomValues, &values_term) ||
            !enif_get_map_value(env, list, kAtomBitOffsetKey, &offset_term)) {
            snprintf(error_out->message, sizeof(error_out->message),
                "Expected list data batch to have offsets, validity, values, and bit_offset keys");
            return 1;
        }

        // Build child array from the values list.
        // values_term is a list of child data items; iterate and process each
        // into the same child array via adbc_column_to_adbc_field.
        nanoarrow::UniqueArray child_array;
        struct ArrowSchema child_schema{};
        bool child_initialized = false;

        ERL_NIF_TERM val_head, val_tail = values_term;
        while (enif_get_list_cell(env, val_tail, &val_head, &val_tail)) {
            struct AdbcColumnNifTerm child_column;
            child_column.is_nil = 0;
            child_column.type_term = inner_type_term;
            child_column.data_term = val_head;
            child_column.name_term = kAtomNil;
            child_column.metadata_term = kAtomNil;
            child_column.struct_name_term = kAtomAdbcFieldModule;
            child_column.n_items = 0;

            if (!child_initialized) {
                int ret = adbc_column_to_adbc_field(env, &child_column, true, child_array.get(), &child_schema, error_out);
                if (ret != 0) {
                    if (child_schema.release) child_schema.release(&child_schema);
                    return ret;
                }
                child_initialized = true;
            } else {
                nanoarrow::UniqueArray extra_array;
                struct ArrowSchema extra_schema{};
                int ret = adbc_column_to_adbc_field(env, &child_column, true, extra_array.get(), &extra_schema, error_out);
                if (extra_schema.release) extra_schema.release(&extra_schema);
                if (ret != 0) return ret;

                // Append extra buffers into child array
                for (int64_t b = 0; b < extra_array.get()->n_buffers; b++) {
                    struct ArrowBuffer* dst = ArrowArrayBuffer(child_array.get(), b);
                    struct ArrowBuffer* src = ArrowArrayBuffer(extra_array.get(), b);
                    if (src->size_bytes > 0) {
                        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(dst, src->data, src->size_bytes));
                    }
                }
                child_array.get()->length += extra_array.get()->length;
                child_array.get()->null_count += extra_array.get()->null_count;
            }
        }

        // Now set up the parent schema's child from the built child schema
        if (schema_out->children[0]->release) {
            schema_out->children[0]->release(schema_out->children[0]);
        }
        ArrowSchemaMove(&child_schema, schema_out->children[0]);

        NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(array_out, schema_out, error_out));
        NANOARROW_RETURN_NOT_OK(ArrowArrayStartAppending(array_out));

        // Move child array data into the parent's child slot
        ArrowArrayMove(child_array.get(), array_out->children[0]);

        // Read offsets binary
        ErlNifBinary offsets_bin;
        if (!enif_inspect_binary(env, offsets_term, &offsets_bin)) {
            snprintf(error_out->message, sizeof(error_out->message), "Expected offsets to be a binary");
            return 1;
        }

        bool has_validity = !enif_is_identical(validity_term, kAtomNil);
        ErlNifBinary validity_bin;
        int bit_offset = 0;
        if (has_validity) {
            if (!enif_inspect_binary(env, validity_term, &validity_bin)) return 1;
        }
        if (!enif_get_int(env, offset_term, &bit_offset)) return 1;

        // Determine element count from offsets binary
        size_t offset_elem_size = (column_type->arrow_type == NANOARROW_TYPE_LARGE_LIST) ? 8 : 4;
        size_t n_elements = (offsets_bin.size / offset_elem_size) - 1;

        // Copy offsets into the list's offset buffer (buffer index 1).
        // Skip the first offset (0) since ArrowArrayStartAppending already wrote it.
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(array_out, 1),
            offsets_bin.data + offset_elem_size, offsets_bin.size - offset_elem_size));

        if (has_validity) {
            NANOARROW_RETURN_NOT_OK(copy_validity_bitmap(validity_bin.data, bit_offset, n_elements, array_out));
        }
        array_out->length = n_elements;

        NANOARROW_RETURN_NOT_OK(ArrowArrayFinishBuildingDefault(array_out, error_out));
    }

    return 0;
}

// non-zero return value indicates there was no metadata or an error
int build_metadata_from_nif(ErlNifEnv *env, ERL_NIF_TERM metadata_term, struct ArrowBuffer *metadata_buffer, struct ArrowError* error_out) {
    NANOARROW_RETURN_NOT_OK(ArrowMetadataBuilderInit(metadata_buffer, nullptr));
    if (enif_is_map(env, metadata_term)) {
        ERL_NIF_TERM metadata_key, metadata_value;
        ErlNifMapIterator iter;
        enif_map_iterator_create(env, metadata_term, &iter, ERL_NIF_MAP_ITERATOR_FIRST);
        while (enif_map_iterator_get_pair(env, &iter, &metadata_key, &metadata_value)) {
            ErlNifBinary key_bytes, value_bytes;
            struct ArrowStringView key_view{};
            struct ArrowStringView value_view{};
            if (enif_inspect_iolist_as_binary(env, metadata_key, &key_bytes)) {
                key_view.data = (const char *)key_bytes.data;
                key_view.size_bytes = static_cast<int64_t>(key_bytes.size);
            } else {
                ArrowBufferReset(metadata_buffer);
                enif_map_iterator_destroy(env, &iter);
                snprintf(error_out->message, sizeof(error_out->message), "cannot get metadata key");
                return kErrorBufferGetMetadataKey;
            }
            if (enif_inspect_iolist_as_binary(env, metadata_value, &value_bytes)) {
                value_view.data = (const char *)value_bytes.data;
                value_view.size_bytes = static_cast<int64_t>(value_bytes.size);
            } else {
                ArrowBufferReset(metadata_buffer);
                enif_map_iterator_destroy(env, &iter);
                enif_snprintf(error_out->message, sizeof(error_out->message), "cannot get metadata value for key: `%T`", metadata_key);
                return kErrorBufferGetMetadataValue;
            }

            NANOARROW_RETURN_NOT_OK(ArrowMetadataBuilderAppend(metadata_buffer, key_view, value_view));
            enif_map_iterator_next(env, &iter);
        }
        enif_map_iterator_destroy(env, &iter);
    }
    return 0;
}

int must_be_adbc_column(ErlNifEnv *env,
    ERL_NIF_TERM adbc_column,
    ERL_NIF_TERM &struct_name_term,
    ERL_NIF_TERM &name_term,
    ERL_NIF_TERM &type_term,
    ERL_NIF_TERM &metadata_term,
    ERL_NIF_TERM &data_term,
    unsigned *n_items)
{
    if (!enif_is_map(env, adbc_column)) {
        return kErrorBufferIsNotAMap;
    }

    if (!enif_get_map_value(env, adbc_column, kAtomStructKey, &struct_name_term)) {
        return kErrorBufferGetMapValue;
    }
    if (!enif_is_identical(struct_name_term, kAtomAdbcColumnModule)) {
        return kErrorBufferWrongStruct;
    }

    // Get the field sub-map
    ERL_NIF_TERM field_term;
    if (!enif_get_map_value(env, adbc_column, kAtomFieldKey, &field_term)) {
        return kErrorBufferGetMapValue;
    }
    if (!enif_is_map(env, field_term)) {
        return kErrorBufferIsNotAMap;
    }

    // Extract field properties from the Field struct
    if (!enif_get_map_value(env, field_term, kAtomNameKey, &name_term)) {
        return kErrorBufferGetMapValue;
    }
    if (!enif_get_map_value(env, field_term, kAtomTypeKey, &type_term)) {
        return kErrorBufferGetMapValue;
    }
    if (!enif_get_map_value(env, field_term, kAtomMetadataKey, &metadata_term)) {
        return kErrorBufferGetMapValue;
    }

    // Get data from Column
    if (!enif_get_map_value(env, adbc_column, kAtomDataKey, &data_term)) {
        return kErrorBufferGetMapValue;
    }

    if (n_items) {
        *n_items = 0;
    }

    return 0;
}

struct AdbcColumnType adbc_column_type_to_nanoarrow_type(ErlNifEnv *env, ERL_NIF_TERM type_term) {
    struct AdbcColumnType ret{};
    ret.valid = 1;

    if (enif_is_identical(type_term, kAdbcColumnTypeBool)) {
        ret.arrow_type = NANOARROW_TYPE_BOOL;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeS8)) {
        ret.arrow_type = NANOARROW_TYPE_INT8;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeU8)) {
        ret.arrow_type = NANOARROW_TYPE_UINT8;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeS16)) {
        ret.arrow_type = NANOARROW_TYPE_INT16;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeU16)) {
        ret.arrow_type = NANOARROW_TYPE_UINT16;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeS32)) {
        ret.arrow_type = NANOARROW_TYPE_INT32;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeU32)) {
        ret.arrow_type = NANOARROW_TYPE_UINT32;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeS64)) {
        ret.arrow_type = NANOARROW_TYPE_INT64;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeU64)) {
        ret.arrow_type = NANOARROW_TYPE_UINT64;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeF16)) {
        ret.arrow_type = NANOARROW_TYPE_HALF_FLOAT;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeF32)) {
        ret.arrow_type = NANOARROW_TYPE_FLOAT;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeF64)) {
        ret.arrow_type = NANOARROW_TYPE_DOUBLE;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeBinary)) {
        ret.arrow_type = NANOARROW_TYPE_BINARY;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeLargeBinary)) {
        ret.arrow_type = NANOARROW_TYPE_LARGE_BINARY;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeString)) {
        ret.arrow_type = NANOARROW_TYPE_STRING;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeLargeString)) {
        ret.arrow_type = NANOARROW_TYPE_LARGE_STRING;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeDate32)) {
        ret.arrow_type = NANOARROW_TYPE_DATE32;
    } else if (enif_is_identical(type_term, kAdbcColumnTypeDate64)) {
        ret.arrow_type = NANOARROW_TYPE_DATE64;
    } else if (enif_is_tuple(env, type_term)) {
        if (enif_is_identical(type_term, kAdbcColumnTypeTime32Seconds)) {
            ret.arrow_type = NANOARROW_TYPE_TIME32;
            ret.time_unit = NANOARROW_TIME_UNIT_SECOND;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeTime32Milliseconds)) {
            ret.arrow_type = NANOARROW_TYPE_TIME32;
            ret.time_unit = NANOARROW_TIME_UNIT_MILLI;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeTime64Microseconds)) {
            ret.arrow_type = NANOARROW_TYPE_TIME64;
            ret.time_unit = NANOARROW_TIME_UNIT_MICRO;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeTime64Nanoseconds)) {
            ret.arrow_type = NANOARROW_TYPE_TIME64;
            ret.time_unit = NANOARROW_TIME_UNIT_NANO;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeDurationSeconds)) {
            ret.arrow_type = NANOARROW_TYPE_DURATION;
            ret.time_unit = NANOARROW_TIME_UNIT_SECOND;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeDurationMilliseconds)) {
            ret.arrow_type = NANOARROW_TYPE_DURATION;
            ret.time_unit = NANOARROW_TIME_UNIT_MILLI;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeDurationMicroseconds)) {
            ret.arrow_type = NANOARROW_TYPE_DURATION;
            ret.time_unit = NANOARROW_TIME_UNIT_MICRO;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeDurationNanoseconds)) {
            ret.arrow_type = NANOARROW_TYPE_DURATION;
            ret.time_unit = NANOARROW_TIME_UNIT_NANO;
        }  else if (enif_is_identical(type_term, kAdbcColumnTypeIntervalMonth)) {
            ret.arrow_type = NANOARROW_TYPE_INTERVAL_MONTHS;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeIntervalDayTime)) {
            ret.arrow_type = NANOARROW_TYPE_INTERVAL_DAY_TIME;
        } else if (enif_is_identical(type_term, kAdbcColumnTypeIntervalMonthDayNano)) {
            ret.arrow_type = NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO;
        } else {
            const ERL_NIF_TERM *tuple = nullptr;
            int arity;
            if (enif_get_tuple(env, type_term, &arity, &tuple)) {
                if (arity == 2) {
                    if (enif_is_identical(tuple[0], kAdbcColumnTypeList)) {
                        ret.arrow_type = NANOARROW_TYPE_LIST;
                    } else if (enif_is_identical(tuple[0], kAdbcColumnTypeLargeList)) {
                        ret.arrow_type = NANOARROW_TYPE_LARGE_LIST;
                    } else if (enif_is_identical(tuple[0], kAtomFixedSizeBinary)) {
                        int32_t fixed_size;
                        if (erlang::nif::get(env, tuple[1], &fixed_size)) {
                            ret.arrow_type = NANOARROW_TYPE_FIXED_SIZE_BINARY;
                            ret.fixed_size = fixed_size;
                        } else {
                            ret.valid = 0;
                        }
                    } else {
                        ret.valid = 0;
                    }
                } else if (arity == 3) {
                    if (enif_is_identical(tuple[0], kAtomFixedSizeList)) {
                        int32_t fixed_size;
                        if (erlang::nif::get(env, tuple[2], &fixed_size)) {
                            ret.arrow_type = NANOARROW_TYPE_FIXED_SIZE_LIST;
                            ret.fixed_size = fixed_size;
                        } else {
                            ret.valid = 0;
                        }
                    } else
                    if (enif_is_identical(tuple[0], kAdbcColumnTypeDictionary)) {
                        ret.arrow_type = NANOARROW_TYPE_DICTIONARY;
                    } else if (enif_is_identical(tuple[0], kAtomTimestamp)) {
                        ret.arrow_type = NANOARROW_TYPE_TIMESTAMP;
                        std::string timezone;
                        if (erlang::nif::get(env, tuple[2], timezone) && !timezone.empty()) {
                            ret.timezone = timezone;
                            if (enif_is_identical(tuple[1], kAtomSeconds)) {
                                ret.time_unit = NANOARROW_TIME_UNIT_SECOND;
        
                            } else if (enif_is_identical(tuple[1], kAtomMilliseconds)) {
                                ret.time_unit = NANOARROW_TIME_UNIT_MILLI;
        
                            } else if (enif_is_identical(tuple[1], kAtomMicroseconds)) {
                                ret.time_unit = NANOARROW_TIME_UNIT_MICRO;
        
                            } else if (enif_is_identical(tuple[1], kAtomNanoseconds)) {
                                ret.time_unit = NANOARROW_TIME_UNIT_NANO;
        
                            } else {
                                ret.valid = 0;
                            }
                        } else {
                            ret.valid = 0;
                        }
                    } else if (enif_is_identical(tuple[0], kAtomDecimal128)) {
                        int precision = 0;
                        int scale = 0;
                        if (erlang::nif::get(env, tuple[1], &precision) && erlang::nif::get(env, tuple[2], &scale)) {
                            ret.bits = 128;
                            ret.precision = precision;
                            ret.scale = scale;
                            ret.arrow_type = NANOARROW_TYPE_DECIMAL128;
                        } else {
                            ret.valid = 0;
                        }
                    } else if (enif_is_identical(tuple[0], kAtomDecimal256)) {
                        int precision = 0;
                        int scale = 0;
                        if (erlang::nif::get(env, tuple[1], &precision) && erlang::nif::get(env, tuple[2], &scale)) {
                            ret.bits = 256;
                            ret.precision = precision;
                            ret.scale = scale;
                            ret.arrow_type = NANOARROW_TYPE_DECIMAL256;
                        } else {
                            ret.valid = 0;
                        }
                    } else {
                        ret.valid = 0;
                    }
                } else {
                    ret.valid = 0;
                }
            } else {
                ret.valid = 0;
            }
        }
    }

    return ret;
}

// non-zero return value indicating errors
int adbc_column_to_adbc_field(ErlNifEnv *env, struct AdbcColumnNifTerm * column, bool allow_nil, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    if (column == nullptr) {
        enif_snprintf(error_out->message, sizeof(error_out->message), "internal error, AdbcColumnNifTerm is null");
        return kErrorInternalError;
    }

    std::string name;
    if (!enif_is_identical(column->name_term, kAtomNil)) {
        if (!erlang::nif::get(env, column->name_term, name)) {
            erlang::nif::get_atom(env, column->name_term, name);
        }
    }

    // Derive nullable from the data's validity field rather than the Field struct.
    // If the data has a non-nil validity bitmap, the column is nullable.
    ERL_NIF_TERM data_term = column->data_term;
    bool nullable = false;
    {
        ERL_NIF_TERM validity_term;
        if (enif_is_map(env, data_term) &&
            enif_get_map_value(env, data_term, kAtomValidity, &validity_term)) {
            nullable = !enif_is_identical(validity_term, kAtomNil);
        }
    }

    ArrowSchemaInit(schema_out);
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetName(schema_out, name.c_str()));

    struct ArrowBuffer metadata_buffer{};
    int metadata_ret = build_metadata_from_nif(env, column->metadata_term, &metadata_buffer, error_out);
    if (metadata_ret) {
        if (schema_out->release) {
            schema_out->release(schema_out);
        }
        return metadata_ret;
    }
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetMetadata(schema_out, (const char*)metadata_buffer.data));
    ArrowBufferReset(&metadata_buffer);

    schema_out->flags |= nullable ? ARROW_FLAG_NULLABLE : schema_out->flags;

    // Data types can be found here:
    // https://arrow.apache.org/docs/format/CDataInterface.html
    struct AdbcColumnType column_type = adbc_column_type_to_nanoarrow_type(env, column->type_term);
    if (column_type.valid == 0) {
        enif_snprintf(error_out->message, sizeof(error_out->message), "unsupport type `%T` found in adbc_column_to_adbc_field:%d", column->type_term, __LINE__);
        return kErrorBufferUnknownType;
    }

    int ret = kErrorBufferUnknownType;
    if (column_type.arrow_type == NANOARROW_TYPE_BOOL) {
        ret = do_get_list_boolean(env, data_term, column_type.arrow_type, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_INT8) {
        ret = do_get_list_integer<int8_t>(env, data_term, NANOARROW_TYPE_INT8, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_UINT8) {
        ret = do_get_list_integer<uint8_t>(env, data_term, NANOARROW_TYPE_UINT8, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_INT16) {
        ret = do_get_list_integer<int16_t>(env, data_term, NANOARROW_TYPE_INT16, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_UINT16) {
        ret = do_get_list_integer<uint16_t>(env, data_term, NANOARROW_TYPE_UINT16, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_INT32) {
        ret = do_get_list_integer<int32_t>(env, data_term, NANOARROW_TYPE_INT32, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_UINT32) {
        ret = do_get_list_integer<uint32_t>(env, data_term, NANOARROW_TYPE_UINT32, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_INT64) {
        ret = do_get_list_integer<int64_t>(env, data_term, NANOARROW_TYPE_INT64, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_UINT64) {
        ret = do_get_list_integer<uint64_t>(env, data_term, NANOARROW_TYPE_UINT64, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_HALF_FLOAT) {
        NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, NANOARROW_TYPE_HALF_FLOAT));
        ret = do_get_buffer_datas(env, data_term, sizeof(uint16_t), array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_FLOAT) {
        NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, NANOARROW_TYPE_FLOAT));
        ret = do_get_buffer_datas(env, data_term, sizeof(float), array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_DOUBLE) {
        NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_out, NANOARROW_TYPE_DOUBLE));
        ret = do_get_buffer_datas(env, data_term, sizeof(double), array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_BINARY) {
        ret = do_get_list_string(env, data_term,NANOARROW_TYPE_BINARY, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_LARGE_BINARY) {
        ret = do_get_list_string(env, data_term,NANOARROW_TYPE_LARGE_BINARY, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_STRING) {
        ret = do_get_list_string(env, data_term,NANOARROW_TYPE_STRING, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_LARGE_STRING) {
        ret = do_get_list_string(env, data_term,NANOARROW_TYPE_LARGE_STRING, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_DATE32) {
        ret = do_get_list_date(env, data_term, NANOARROW_TYPE_DATE32, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_DATE64) {
        ret = do_get_list_date(env, data_term, NANOARROW_TYPE_DATE64, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_LIST) {
        ret = do_get_list(env, column->type_term, data_term, &column_type, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_LARGE_LIST) {
        ret = do_get_list(env, column->type_term, data_term, &column_type, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_FIXED_SIZE_LIST) {
        ret = do_get_list(env, column->type_term, data_term, &column_type, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_TIME32 || column_type.arrow_type == NANOARROW_TYPE_TIME64) {
        ret = do_get_list_time(env, data_term, column_type.arrow_type, column_type.time_unit, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_DURATION) {
        ret = do_get_list_duration(env, data_term, column_type.arrow_type, column_type.time_unit, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_TIMESTAMP) {
        ret = do_get_list_timestamp(env, data_term, column_type.arrow_type, column_type.time_unit, column_type.timezone.c_str(), array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_INTERVAL_MONTHS) {
        ret = do_get_list_interval(env, data_term, column_type.arrow_type, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_INTERVAL_DAY_TIME) {
        ret = do_get_list_interval(env, data_term, column_type.arrow_type, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO) {
        ret = do_get_list_interval(env, data_term, column_type.arrow_type, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_FIXED_SIZE_BINARY) {
        NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeFixedSize(schema_out, column_type.arrow_type, column_type.fixed_size));
        ret = do_get_buffer_datas(env, data_term, column_type.fixed_size, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_DECIMAL128 || column_type.arrow_type == NANOARROW_TYPE_DECIMAL256) {
        ret = do_get_list_decimal(env, data_term, column_type.arrow_type, column_type.bits, column_type.precision, column_type.scale, array_out, schema_out, error_out);
    } else if (column_type.arrow_type == NANOARROW_TYPE_DICTIONARY) {
        ret = do_get_dictionary(env, column->type_term, data_term, array_out, schema_out, error_out);
    }

    if (ret == kErrorBufferUnknownType) {
        enif_snprintf(error_out->message, sizeof(error_out->message), "unsupport type `%T` (arrow_type=%d) found in adbc_column_to_adbc_field:%d", column->type_term, column_type.arrow_type, __LINE__);
    }
    return ret;
}

int adbc_column_to_adbc_field(ErlNifEnv *env, ERL_NIF_TERM adbc_column, bool allow_nil, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out, unsigned *n_items) {
    struct AdbcColumnNifTerm column;
    int ret = AdbcColumnNifTerm::from_term(env, adbc_column, allow_nil, &column);
    if (ret != 0) {
        return ret;
    }

    ret = adbc_column_to_adbc_field(env, &column, allow_nil, array_out, schema_out, error_out);
    if (n_items) {
        *n_items = array_out->length;
    }
    return ret;
}

// non-zero return value indicating errors
int adbc_column_to_arrow_type_struct(ErlNifEnv *env, ERL_NIF_TERM values, struct ArrowArray* array_out, struct ArrowSchema* schema_out, struct ArrowError* error_out) {
    unsigned n_items = 0;
    if (!enif_get_list_length(env, values, &n_items)) {
        return 1;
    }

    ArrowSchemaInit(schema_out);
    NANOARROW_RETURN_NOT_OK(ArrowSchemaSetTypeStruct(schema_out, n_items));
    NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromType(array_out, NANOARROW_TYPE_STRUCT));
    NANOARROW_RETURN_NOT_OK(ArrowArrayAllocateChildren(array_out, static_cast<int64_t>(n_items)));
    array_out->length = 1;

    ERL_NIF_TERM head, tail;
    tail = values;
    int64_t processed = 0;
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        auto schema_i = schema_out->children[processed];
        auto child_i = array_out->children[processed];

        if (enif_is_map(env, head)) {
            ERL_NIF_TERM data_term;
            if (!enif_get_map_value(env, head, kAtomDataKey, &data_term)) {
                snprintf(error_out->message, sizeof(error_out->message), "Expected `%%Adbc.Column{}` to have a `data` field.");
                return 1;
            }

            // Check if data_term contains any references (unmaterialized data)
            // If so, reject it with a clear error message
            if (enif_is_ref(env, data_term)) {
                snprintf(error_out->message, sizeof(error_out->message),
                    "Cannot use unmaterialized `Adbc.Column` data (reference type). "
                    "Please call `Adbc.Result.materialize/1` or `Adbc.Column.materialize/1` first.");
                return 1;
            }


            ArrowSchemaInit(schema_i);
            unsigned n_items = 0;
            int ret = adbc_column_to_adbc_field(env, head, false, child_i, schema_i, error_out, &n_items);
            if (array_out->length == 1 && n_items != 0) {
                array_out->length = n_items;
            }
            switch (ret)
            {
            case kErrorBufferIsNotAMap:
            case kErrorBufferWrongStruct:
                snprintf(error_out->message, sizeof(error_out->message), "Expected `%%Adbc.Column{}` or primitive data types.");
                return 1;
            case kErrorBufferGetMapValue:
                snprintf(error_out->message, sizeof(error_out->message), "Invalid `%%Adbc.Column{}`.");
                return 1;
            case kErrorBufferGetDataListLength:
            case kErrorBufferDataIsNotAList:
                snprintf(error_out->message, sizeof(error_out->message), "Expected the `data` field of `Adbc.Column` to be a list of values.");
                return 1;
            case kErrorBufferDataIsNotAMap:
                snprintf(error_out->message, sizeof(error_out->message), "Expected the `data` field of dictionary `Adbc.Column` to be a map.");
                return 1;
            case kErrorBufferUnknownType:
            case kErrorBufferGetMetadataKey:
            case kErrorBufferGetMetadataValue:
            case kErrorInternalError:
                // error message is already set
                return 1;
            default:
                if (ret != 0) {
                    return ret;
                }
                break;
            }
        } else {
            ArrowSchemaInit(schema_i);

            ErlNifSInt64 i64;
            double f64;
            ErlNifBinary bytes;

            if (enif_get_int64(env, head, &i64)) {
                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_i, NANOARROW_TYPE_INT64));
                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetName(schema_i, ""));
                NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(child_i, schema_i, error_out));
                NANOARROW_RETURN_NOT_OK(ArrowArrayStartAppending(child_i));
                NANOARROW_RETURN_NOT_OK(ArrowArrayAppendInt(child_i, i64));
            } else if (enif_get_double(env, head, &f64)) {
                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_i, NANOARROW_TYPE_DOUBLE));
                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetName(schema_i, ""));
                NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(child_i, schema_i, error_out));
                NANOARROW_RETURN_NOT_OK(ArrowArrayStartAppending(child_i));
                NANOARROW_RETURN_NOT_OK(ArrowArrayAppendDouble(child_i, f64));
            } else if (enif_inspect_iolist_as_binary(env, head, &bytes)) {
                auto type = NANOARROW_TYPE_STRING;
                if (bytes.size > INT32_MAX) {
                    type = NANOARROW_TYPE_LARGE_STRING;
                }
                struct ArrowStringView view{};
                view.data = (const char*)(bytes.data);
                view.size_bytes = static_cast<int64_t>(bytes.size);
                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_i, type));
                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetName(schema_i, ""));
                NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(child_i, schema_i, error_out));
                NANOARROW_RETURN_NOT_OK(ArrowArrayStartAppending(child_i));
                NANOARROW_RETURN_NOT_OK(ArrowArrayAppendString(child_i, view));
            } else if (enif_is_atom(env, head)) {
                int64_t val{};
                auto type = NANOARROW_TYPE_BOOL;
                if (enif_is_identical(head, kAtomTrue)) {
                    val = 1;
                } else if (enif_is_identical(head, kAtomFalse)) {
                    val = 0;
                } else if (enif_is_identical(head, kAtomNil)) {
                    type = NANOARROW_TYPE_NA;
                } else {
                    enif_snprintf(error_out->message, sizeof(error_out->message), "atom `:%T` is not supported yet.", head);
                    return 1;
                }

                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetType(schema_i, type));
                NANOARROW_RETURN_NOT_OK(ArrowSchemaSetName(schema_i, ""));
                NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromSchema(child_i, schema_i, error_out));
                NANOARROW_RETURN_NOT_OK(ArrowArrayStartAppending(child_i));
                if (type == NANOARROW_TYPE_BOOL) {
                    NANOARROW_RETURN_NOT_OK(ArrowArrayAppendInt(child_i, val));
                } else {
                    // 1x Null
                    val = 1;
                    NANOARROW_RETURN_NOT_OK(ArrowArrayAppendNull(child_i, val));
                }
            } else {
                enif_snprintf(error_out->message, sizeof(error_out->message), "unsupported parameter `%T` in adbc_column_to_arrow_type_struct:%d", head, __LINE__);
                return 1;
            }
        }
        processed++;
    }

    NANOARROW_RETURN_NOT_OK(ArrowArrayFinishBuilding(array_out, NANOARROW_VALIDATION_LEVEL_FULL, error_out));
    return !(processed == n_items);
}

#endif  // ADBC_COLUMN_HPP
