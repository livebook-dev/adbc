#ifndef ADBC_ARROW_ARRAY_HPP
#define ADBC_ARROW_ARRAY_HPP
#pragma once

#include <stdio.h>
#include <cmath>
#include <cstdbool>
#include <cstdint>
#include <vector>
#include <arrow-adbc/adbc.h>
#include <erl_nif.h>
#include "adbc_arrow_metadata.hpp"

static int arrow_array_to_nif_term(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, std::vector<ERL_NIF_TERM> &out_terms, ERL_NIF_TERM &value_type, ERL_NIF_TERM &metadata, ERL_NIF_TERM &error, bool skip_dictionary_check, void* resource);
static int arrow_array_to_nif_term(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, int64_t level, std::vector<ERL_NIF_TERM> &out_terms, ERL_NIF_TERM &value_type, ERL_NIF_TERM &metadata, ERL_NIF_TERM &error, bool skip_dictionary_check, void* resource);
static int get_arrow_struct(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, std::vector<ERL_NIF_TERM> &children, ERL_NIF_TERM &error, void* resource);
static int get_arrow_struct(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, std::vector<ERL_NIF_TERM> &children, ERL_NIF_TERM &error, void* resource);
static ERL_NIF_TERM get_arrow_array_map_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, void* resource);
static ERL_NIF_TERM get_arrow_array_map_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, void* resource);
static ERL_NIF_TERM get_arrow_array_list_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, ArrowType list_type, unsigned n_items, void* resource);
static ERL_NIF_TERM get_arrow_array_list_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, ArrowType list_type, unsigned n_items, void* resource);
static ERL_NIF_TERM get_arrow_array_dense_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, void* resource);
static ERL_NIF_TERM get_arrow_array_dense_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, void* resource);
static ERL_NIF_TERM get_arrow_array_sparse_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, void* resource);
static ERL_NIF_TERM get_arrow_array_sparse_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, void* resource);

static ERL_NIF_TERM string_views_from_buffer(
    ErlNifEnv *env,
    int64_t element_offset,
    int64_t element_count,
    const uint8_t * validity_bitmap,
    const uint8_t * views_buffer,
    int64_t n_data_buffers,
    const uint8_t * const * data_buffers) {

    std::vector<ERL_NIF_TERM> values(element_count);

    for (int64_t i = element_offset; i < element_offset + element_count; i++) {
        bool is_valid = (validity_bitmap == nullptr) || (validity_bitmap[i / 8] & (1 << (i % 8)));

        if (!is_valid) {
            values[i - element_offset] = kAtomNil;
            continue;
        }

        // Each view is a 16-byte struct
        const uint8_t* view = views_buffer + i * 16;
        int32_t length;
        memcpy(&length, view, 4);

        if (length == 0) {
            values[i - element_offset] = kAtomNil;
        } else if (length <= 12) {
            // Short string: data is stored inline in bytes [4..4+length)
            values[i - element_offset] = erlang::nif::make_binary(env, (const char*)(view + 4), (size_t)length);
        } else {
            // Long string: bytes [8..12) = buf_index, bytes [12..16) = offset into buffer
            int32_t buf_index, buf_offset;
            memcpy(&buf_index, view + 8, 4);
            memcpy(&buf_offset, view + 12, 4);
            values[i - element_offset] = erlang::nif::make_binary(env, (const char*)(data_buffers[buf_index] + buf_offset), (size_t)length);
        }
    }

    return enif_make_list_from_array(env, values.data(), (unsigned)values.size());
}

int get_arrow_struct(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, std::vector<ERL_NIF_TERM> &children, ERL_NIF_TERM &error, void* resource) {
    if (schema->n_children > 0 && schema->children == nullptr) {
        error = erlang::nif::error(env, "invalid ArrowSchema, schema->children == nullptr while schema->n_children > 0");
        return 1;
    }
    if (values->n_children > 0 && values->children == nullptr) {
        error =  erlang::nif::error(env, "invalid ArrowArray, values->children == nullptr while values->n_children > 0");
        return 1;
    }
    if (values->n_children != schema->n_children) {
        error =  erlang::nif::error(env, "invalid ArrowArray or ArrowSchema, values->n_children != schema->n_children");
        return 1;
    }

    children.resize(values->n_children);
    for (int64_t child_i = 0; child_i < values->n_children; child_i++) {
        struct ArrowSchema * child_schema = schema->children[child_i];
        struct ArrowArray * child_values = values->children[child_i];
        std::vector<ERL_NIF_TERM> childrens;
        ERL_NIF_TERM child_type;
        ERL_NIF_TERM child_metadata;
        if (arrow_array_to_nif_term(env, child_schema, child_values, offset, count, level + 1, childrens, child_type, child_metadata, error, false, resource) == 1) {
            return 1;
        }

        // Return plain data for each struct field (no Column wrappers)
        if (childrens.size() == 1) {
            children[child_i] = childrens[0];
        } else {
            children[child_i] = enif_is_identical(childrens[1], kAtomNil) ? kAtomNil : childrens[1];
        }
    }
    return 0;
}

int get_arrow_struct(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, std::vector<ERL_NIF_TERM> &children, ERL_NIF_TERM &error, void* resource) {
    return get_arrow_struct(env, schema, values, 0, -1, level, children, error, resource);
}

int get_arrow_dictionary(ErlNifEnv *env,
    struct ArrowSchema * index_schema, struct ArrowArray * index_array,
    struct ArrowSchema * value_schema, struct ArrowArray * value_array,
    int64_t offset, int64_t count, uint64_t level, std::vector<ERL_NIF_TERM> &children, ERL_NIF_TERM &error, void* resource) {
    std::vector<ERL_NIF_TERM> keys, values;
    ERL_NIF_TERM index_type, index_metadata;
    ERL_NIF_TERM value_type, value_metadata;
    if (arrow_array_to_nif_term(env, index_schema, index_array, offset, count, level + 1, keys, index_type, index_metadata, error, true, resource) == 1) {
        return 1;
    }
    if (arrow_array_to_nif_term(env, value_schema, value_array, offset, count, level + 1, values, value_type, value_metadata, error, false, resource) == 1) {
        return 1;
    }

    ERL_NIF_TERM key_data = keys[1];
    ERL_NIF_TERM value_data = values[1];
    ERL_NIF_TERM data;
    ERL_NIF_TERM data_keys[] = {
        kAtomStructKey,
        kAtomKey,
        kAtomValue
    };
    ERL_NIF_TERM data_values[] = {
        kAtomAdbcDictionaryDataModule,
        key_data,
        value_data
    };
    enif_make_map_from_arrays(env, data_keys, data_values, (unsigned)(sizeof(data_keys)/sizeof(data_keys[0])), &data);
    children.push_back(data);
    return 0;
}

int get_arrow_dictionary(ErlNifEnv *env,
    struct ArrowSchema * index_schema, struct ArrowArray * index_array,
    struct ArrowSchema * value_schema, struct ArrowArray * value_array,
    uint64_t level, std::vector<ERL_NIF_TERM> &children, ERL_NIF_TERM &error, void* resource) {
    return get_arrow_dictionary(env, index_schema, index_array, value_schema, value_array, 0, -1, level, children, error, resource);
}

ERL_NIF_TERM get_arrow_array_map_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, void* resource) {
    // From https://arrow.apache.org/docs/format/CDataInterface.html#data-type-description-format-strings
    //
    //   As specified in the Arrow columnar format, the map type has a single child type named entries,
    //   itself a 2-child struct type of (key, value).

    ERL_NIF_TERM error{}, map_out{};
    if (schema->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowSchema (map), schema->children == nullptr");
    }
    if (schema->n_children != 1) {
        return erlang::nif::error(env, "invalid ArrowSchema (map), schema->n_children != 1");
    }
    if (values->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowArray (map), values->children == nullptr");
    }
    if (values->n_children != 1) {
        return erlang::nif::error(env, "invalid ArrowArray (map), values->n_children != 1");
    }

    struct ArrowSchema * entries_schema = schema->children[0];
    struct ArrowArray * entries_values = values->children[0];
    if (strcmp("entries", entries_schema->name) != 0) {
        return erlang::nif::error(env, "invalid ArrowSchema (map), its single child is not named entries");
    }
    if (entries_schema->n_children != 2) {
        return erlang::nif::error(env, "invalid ArrowSchema (map), its entries n_children != 2");
    }

    struct ArrowSchema * key_schema, * value_schema;
    struct ArrowArray * key_values, * value_values;
    if (strcmp("key", entries_schema->children[0]->name) == 0 && strcmp("value", entries_schema->children[1]->name) == 0) {
        key_schema = entries_schema->children[0];
        key_values = entries_values->children[0];
        value_schema = entries_schema->children[1];
        value_values = entries_values->children[1];
    } else if (strcmp("key", entries_schema->children[1]->name) == 0 && strcmp("value", entries_schema->children[0]->name) == 0) {
        key_schema = entries_schema->children[1];
        key_values = entries_values->children[1];
        value_schema = entries_schema->children[0];
        value_values = entries_values->children[0];
    } else {
        return erlang::nif::error(env, "invalid map entries, key or value or both are missing");
    }

    std::vector<ERL_NIF_TERM> nif_keys, nif_values;
    ERL_NIF_TERM key_type, key_metadata;
    ERL_NIF_TERM value_type, value_metadata;
    if (arrow_array_to_nif_term(env, key_schema, key_values, offset, count, level + 1, nif_keys, key_type, key_metadata, error, false, resource) == 1) {
        return erlang::nif::error(env, "failed to get map keys");
    }
    if (arrow_array_to_nif_term(env, value_schema, value_values, offset, count, level + 1, nif_values, value_type, value_metadata, error, false, resource) == 1) {
        return erlang::nif::error(env, "failed to get map values");
    }

    ERL_NIF_TERM map_keys[] = {
        kAtomKey,
        kAtomValue
    };
    ERL_NIF_TERM map_values[] = {
        make_adbc_column(env, key_schema, key_values, nif_keys[0], key_type, key_metadata, nif_keys[1]),
        make_adbc_column(env, value_schema, value_values, nif_values[0], value_type, value_metadata, nif_values[1])
    };

    enif_make_map_from_arrays(env, map_keys, map_values, (unsigned)(sizeof(map_keys)/sizeof(map_keys[0])), &map_out);
    return map_out;
}

ERL_NIF_TERM get_arrow_array_map_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, void* resource) {
    return get_arrow_array_map_children(env, schema, values, 0, -1, level, resource);
}

ERL_NIF_TERM get_arrow_array_dense_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, void* resource) {
    ERL_NIF_TERM error{};
    if (schema->n_children > 0 && schema->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowSchema (dense union), schema->children == nullptr while schema->n_children > 0 ");
    }
    if (values->n_children > 0 && values->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowArray (dense union), values->children == nullptr while values->n_children > 0");
    }
    if (offset < 0 || offset >= values->length) {
        return erlang::nif::error(env, "invalid offset value when parsing ArrowArray (dense union), offset < 0 || offset >= values->length");
    }
    if (count == -1) count = values->length;
    if ((offset + count) > values->length) {
        return erlang::nif::error(env, "invalid offset or count value when parsing ArrowArray (dense union), (offset + count) > values->length");
    }
    if (values->n_buffers != 2) {
        return erlang::nif::error(env, "invalid ArrowArray (dense union), values->n_buffers != 2");
    }

    constexpr int64_t types_buffer_index = 0;
    constexpr int64_t offset_buffer_index = 1;
    const uint8_t * types_buffer = (const uint8_t *)values->buffers[types_buffer_index];
    const int32_t * offsets_buffer = (const int32_t *)values->buffers[offset_buffer_index];

    std::vector<ERL_NIF_TERM> elements(count);
    for (int64_t child_i = offset; child_i < offset + count; child_i++) {
        uint8_t child_type = types_buffer[child_i];
        int32_t child_offset = offsets_buffer[child_i];
        if (child_type >= schema->n_children || child_type >= values->n_children) {
            return erlang::nif::error(env, "invalid child type when parsing ArrowArray (dense union), child_type >= schema->n_children || child_type >= values->n_children");
        }
        struct ArrowSchema * field_schema = schema->children[child_type];
        struct ArrowArray * field_array = values->children[child_type];

        std::vector<ERL_NIF_TERM> union_element_name(1), union_element_value(1);
        std::vector<ERL_NIF_TERM> field_values;
        union_element_name[0] = erlang::nif::make_binary(env, field_schema->name);

        ERL_NIF_TERM field_type;
        ERL_NIF_TERM field_metadata;
        if (arrow_array_to_nif_term(env, field_schema, field_array, child_offset, 1, level + 1, field_values, field_type, field_metadata, error, false, resource) == 1) {
            return error;
        }

        if (field_values.size() == 1) {
            union_element_value[0] = field_values[0];
        } else if (field_values.size() == 2) {
            union_element_value[0] = field_values[1];
        } else {
            return erlang::nif::error(env, "invalid dense union field value");
        }

        ERL_NIF_TERM element{};
        if (!enif_make_map_from_arrays(env, union_element_name.data(), union_element_value.data(), 1, &element)) {
            return erlang::nif::error(env, "failed to enif_make_map_from_arrays when parsing ArrowSchema (dense union)");
        }
        elements[child_i - offset] = element;
    }

    return enif_make_list_from_array(env, elements.data(), (unsigned)elements.size());
}

ERL_NIF_TERM get_arrow_array_dense_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, void* resource) {
    return get_arrow_array_dense_union_children(env, schema, values, 0, -1, level, resource);
}

ERL_NIF_TERM get_arrow_array_sparse_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, void* resource) {
    ERL_NIF_TERM error{};
    if (schema->n_children > 0 && schema->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowSchema (sparse union), schema->children == nullptr while schema->n_children > 0 ");
    }
    if (values->n_children > 0 && values->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowArray (sparse union), values->children == nullptr while values->n_children > 0");
    }
    if (offset < 0 || offset >= values->length) {
        return erlang::nif::error(env, "invalid offset value when parsing ArrowArray (sparse union), offset < 0 || offset >= values->length");
    }
    if (count == -1) count = values->length;
    if ((offset + count) > values->length) {
        return erlang::nif::error(env, "invalid offset or count value when parsing ArrowArray (sparse union), (offset + count) > values->length");
    }
    if (values->n_buffers != 1) {
        return erlang::nif::error(env, "invalid ArrowArray (sparse union), values->n_buffers != 1");
    }

    constexpr int64_t types_buffer_index = 0;
    const uint8_t * types_buffer = (const uint8_t *)values->buffers[types_buffer_index];

    std::vector<ERL_NIF_TERM> elements(count);
    for (int64_t child_i = offset; child_i < offset + count; child_i++) {
        uint8_t child_type = types_buffer[child_i];
        if (child_type >= schema->n_children || child_type >= values->n_children) {
            return erlang::nif::error(env, "invalid child type when parsing ArrowArray (sparse union), child_type >= schema->n_children || child_type >= values->n_children");
        }
        struct ArrowSchema * field_schema = schema->children[child_type];
        struct ArrowArray * field_array = values->children[child_type];

        std::vector<ERL_NIF_TERM> union_element_name(1), union_element_value(1);
        std::vector<ERL_NIF_TERM> field_values;
        union_element_name[0] = erlang::nif::make_binary(env, field_schema->name);

        ERL_NIF_TERM field_type;
        // todo: use field_metadata
        ERL_NIF_TERM field_metadata;
        if (arrow_array_to_nif_term(env, field_schema, field_array, child_i, 1, level + 1, field_values, field_type, field_metadata, error, false, resource) == 1) {
            return error;
        }

        if (field_values.size() == 1) {
            union_element_value[0] = field_values[0];
        } else if (field_values.size() == 2) {
            union_element_value[0] = field_values[1];
        } else {
            return erlang::nif::error(env, "invalid sparse union field value");
        }

        ERL_NIF_TERM element{};
        if (!enif_make_map_from_arrays(env, union_element_name.data(), union_element_value.data(), 1, &element)) {
            return erlang::nif::error(env, "failed to enif_make_map_from_arrays when parsing ArrowSchema (sparse union)");
        }
        elements[child_i - offset] = element;
    }

    return enif_make_list_from_array(env, elements.data(), (unsigned)elements.size());
}

ERL_NIF_TERM get_arrow_array_sparse_union_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, void* resource) {
    return get_arrow_array_sparse_union_children(env, schema, values, 0, -1, level, resource);
}

ERL_NIF_TERM get_arrow_run_end_encoded(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, void* resource) {
    ERL_NIF_TERM error{};
    if (schema->n_children != 2 || values->n_children != 2) {
        return erlang::nif::error(env, "invalid ArrowSchema (run_end_encoded), schema->n_children != 2 || values->n_children != 2");
    }
    if (schema->children == nullptr || values->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowArray (run_end_encoded), schema->children == nullptr || values->children == nullptr");
    }
    if (strcmp("run_ends", schema->children[0]->name) != 0) {
        return erlang::nif::error(env, "invalid ArrowSchema (run_end_encoded), its first child is not named run_ends");
    }
    if (strcmp("values", schema->children[1]->name) != 0) {
        return erlang::nif::error(env, "invalid ArrowSchema (run_end_encoded), its second child is not named values");
    }

    std::vector<ERL_NIF_TERM> children(2);
    for (int64_t child_i = 0; child_i < 2; child_i++) {
        std::vector<ERL_NIF_TERM> childrens;
        ERL_NIF_TERM child_type;
        ERL_NIF_TERM child_metadata;
        if (arrow_array_to_nif_term(env, schema->children[child_i], values->children[child_i], 0, -1, level + 1, childrens, child_type, child_metadata, error, false, resource) == 1) {
            return 1;
        }

        // Return plain data for run_ends and values (no Column wrappers)
        if (childrens.size() == 1) {
            children[child_i] = childrens[0];
        } else {
            if (enif_is_identical(childrens[1], kAtomNil)) {
                children[child_i] = kAtomNil;
            } else {
                children[child_i] = childrens[1];
            }
        }
    }

    ERL_NIF_TERM ree_keys[] = { kAtomStructKey, kAtomRunEnds, kAtomValues, kAtomLengthKey, kAtomOffsetKey };
    ERL_NIF_TERM ree_vals[] = {
        kAtomAdbcRunEndEncodedDataModule,
        children[0], children[1],
        enif_make_int64(env, values->length),
        enif_make_int64(env, values->offset)
    };
    ERL_NIF_TERM ree_data;
    enif_make_map_from_arrays(env, ree_keys, ree_vals, 5, &ree_data);
    return ree_data;
}

ERL_NIF_TERM get_arrow_run_end_encoded(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, void* resource) {
    return get_arrow_run_end_encoded(env, schema, values, 0, -1, level, resource);
}

// Slice a validity bitmap at the given element offset, returning {validity_term, bit_offset}.
// The bitmap is sliced to start at byte offset/8, with bit_offset = offset%8.
static void slice_validity_bitmap(ErlNifEnv *env, const uint8_t *bitmap, int64_t offset, int64_t count, void* resource, ERL_NIF_TERM &validity_out, int &bit_offset_out) {
    bit_offset_out = (int)(offset % 8);
    if (bitmap == nullptr) {
        validity_out = kAtomNil;
    } else {
        size_t bitmap_start = offset / 8;
        size_t total_bitmap_bytes = (offset + count + 7) / 8 - bitmap_start;
        validity_out = enif_make_resource_binary(env, resource, bitmap + bitmap_start, total_bitmap_bytes);
    }
}

ERL_NIF_TERM get_arrow_array_list_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, ArrowType list_type, unsigned n_items, void* resource) {
    ERL_NIF_TERM error{};
    if (schema->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowSchema (list), schema->children == nullptr");
    }
    if (schema->n_children != 1) {
        return erlang::nif::error(env, "invalid ArrowSchema (list), schema->n_children != 1");
    }
    if (values->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowArray (list), values->children == nullptr");
    }
    if (values->n_children != 1) {
        return erlang::nif::error(env, "invalid ArrowArray (list), values->n_children != 1");
    }
    if (list_type != NANOARROW_TYPE_LIST && list_type != NANOARROW_TYPE_LARGE_LIST && list_type != NANOARROW_TYPE_FIXED_SIZE_LIST) {
        return erlang::nif::error(env, "invalid ArrowArray (list), internal error: unexpected list type");
    }

    struct ArrowSchema * items_schema = schema->children[0];
    struct ArrowArray * items_values = values->children[0];
    if (count == -1) count = values->length;
    if (count > values->length) count = values->length - offset;

    // Get child column data via arrow_array_to_nif_term (returns buffer tuples, lists, etc.)
    std::vector<ERL_NIF_TERM> childrens;
    ERL_NIF_TERM children_type;
    ERL_NIF_TERM children_metadata;
    if (arrow_array_to_nif_term(env, items_schema, items_values, 0, -1, level + 1, childrens, children_type, children_metadata, error, false, resource) == 1) {
        return error;
    }
    ERL_NIF_TERM values_term = enif_make_list1(env, childrens[1]);

    // Validity bitmap
    const uint8_t * bitmap_buffer = (const uint8_t *)values->buffers[0];
    ERL_NIF_TERM validity_term;
    int bit_offset;
    slice_validity_bitmap(env, bitmap_buffer, offset, count, resource, validity_term, bit_offset);

    // Offsets
    ERL_NIF_TERM offsets_term;
    if (list_type == NANOARROW_TYPE_LIST) {
        constexpr int64_t offset_buffer_index = 1;
        const int32_t * offsets_ptr = (const int32_t *)values->buffers[offset_buffer_index];
        if (offsets_ptr == nullptr) return erlang::nif::error(env, "invalid ArrowArray (list), offsets == nullptr");
        // offsets has count+1 elements
        offsets_term = enif_make_resource_binary(env, resource, &offsets_ptr[offset], (count + 1) * sizeof(int32_t));
    } else if (list_type == NANOARROW_TYPE_LARGE_LIST) {
        constexpr int64_t offset_buffer_index = 1;
        const int64_t * offsets_ptr = (const int64_t *)values->buffers[offset_buffer_index];
        if (offsets_ptr == nullptr) return erlang::nif::error(env, "invalid ArrowArray (list), offsets == nullptr");
        offsets_term = enif_make_resource_binary(env, resource, &offsets_ptr[offset], (count + 1) * sizeof(int64_t));
    } else {
        // NANOARROW_TYPE_FIXED_SIZE_LIST — no offsets, use fixed size
        offsets_term = enif_make_int(env, n_items);
    }

    // Return %Adbc.ListData{}
    ERL_NIF_TERM keys[] = { kAtomStructKey, kAtomOffsets, kAtomValidity, kAtomValues, kAtomBitOffsetKey };
    ERL_NIF_TERM vals[] = { kAtomAdbcListDataModule, offsets_term, validity_term, values_term, enif_make_int(env, bit_offset) };
    ERL_NIF_TERM map_out;
    enif_make_map_from_arrays(env, keys, vals, 5, &map_out);
    return map_out;
}

ERL_NIF_TERM get_arrow_array_list_children(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, ArrowType list_type, unsigned n_items, void* resource) {
    return get_arrow_array_list_children(env, schema, values, 0, -1, level, list_type, n_items, resource);
}

ERL_NIF_TERM get_arrow_array_list_view(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, uint64_t level, ArrowType list_type, void* resource) {
    ERL_NIF_TERM error{};
    if (schema->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowSchema (list view), schema->children == nullptr");
    }
    if (schema->n_children != 1) {
        return erlang::nif::error(env, "invalid ArrowSchema (list view), schema->n_children != 1");
    }
    if (values->children == nullptr) {
        return erlang::nif::error(env, "invalid ArrowArray (list view), values->children == nullptr");
    }
    if (values->n_children != 1) {
        return erlang::nif::error(env, "invalid ArrowArray (list view), values->n_children != 1");
    }
    if (list_type != NANOARROW_TYPE_LIST && list_type != NANOARROW_TYPE_LARGE_LIST) {
        return erlang::nif::error(env, "invalid ArrowArray (list view), internal error: unexpected list type");
    }

    constexpr int64_t bitmap_buffer_index = 0;
    constexpr int64_t offsets_buffer_index = 1;
    constexpr int64_t sizes_buffer_index = 2;
    const uint8_t * bitmap_buffer = (const uint8_t *)values->buffers[bitmap_buffer_index];
    const void * offsets_ptr = (const void *)values->buffers[offsets_buffer_index];
    const void * sizes_ptr = (const void *)values->buffers[sizes_buffer_index];
    if (offsets_ptr == nullptr) return erlang::nif::error(env, "invalid ArrowArray (list view), offsets == nullptr");
    if (sizes_ptr == nullptr) return erlang::nif::error(env, "invalid ArrowArray (list view), sizes == nullptr");

    struct ArrowSchema * items_schema = schema->children[0];
    struct ArrowArray * items_values = values->children[0];
    if (!(strcmp("item", items_schema->name) == 0 || strcmp("l", items_schema->name) == 0)) {
        return erlang::nif::error(env, "invalid ArrowSchema (list), its single child is not named `item` or `l`");
    }
    if (count == -1) count = values->length;
    if (count > values->length) count = values->length - offset;

    std::vector<ERL_NIF_TERM> childrens;
    ERL_NIF_TERM validity_term, offsets_term, sizes_term, values_term;
    ERL_NIF_TERM children_type;
    ERL_NIF_TERM children_metadata;
    // according to the Arrow spec, the bitmap buffer is not required for the child values
    // and this `buffer[0]` could be a random memory address, so we simply set it to nullptr here
    items_values->buffers[0] = nullptr;
    if (arrow_array_to_nif_term(env, items_schema, items_values, 0, -1, level + 1, childrens, children_type, children_metadata, error, false, resource)) {
        return error;
    }
    items_values->buffers[0] = bitmap_buffer;

    // Return plain data for list_view values (no Column wrapper)
    if (childrens.size() == 1) {
        values_term = childrens[0];
    } else {
        values_term = enif_is_identical(childrens[1], kAtomNil) ? kAtomNil : childrens[1];
    }

    // Validity bitmap
    int bit_offset_int;
    slice_validity_bitmap(env, bitmap_buffer, offset, count, resource, validity_term, bit_offset_int);

    // Offsets and sizes as raw binaries
    if (list_type == NANOARROW_TYPE_LIST) {
        const int32_t * off32 = (const int32_t *)offsets_ptr;
        const int32_t * sz32 = (const int32_t *)sizes_ptr;
        offsets_term = enif_make_resource_binary(env, resource, &off32[offset], count * sizeof(int32_t));
        sizes_term = enif_make_resource_binary(env, resource, &sz32[offset], count * sizeof(int32_t));
    } else {
        const int64_t * off64 = (const int64_t *)offsets_ptr;
        const int64_t * sz64 = (const int64_t *)sizes_ptr;
        offsets_term = enif_make_resource_binary(env, resource, &off64[offset], count * sizeof(int64_t));
        sizes_term = enif_make_resource_binary(env, resource, &sz64[offset], count * sizeof(int64_t));
    }

    // Return %Adbc.ListViewData{}
    ERL_NIF_TERM list_view_keys[] = { kAtomStructKey, kAtomOffsets, kAtomSizes, kAtomValidity, kAtomValues, kAtomBitOffsetKey };
    ERL_NIF_TERM list_view_vals[] = { kAtomAdbcListViewDataModule, offsets_term, sizes_term, validity_term, values_term, enif_make_int(env, bit_offset_int) };
    ERL_NIF_TERM map_out;
    enif_make_map_from_arrays(env, list_view_keys, list_view_vals, 6, &map_out);
    return map_out;
}

ERL_NIF_TERM get_arrow_array_list_view(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, ArrowType list_type, void* resource) {
    return get_arrow_array_list_view(env, schema, values, 0, -1, level, list_type, resource);
}

// Build an %Adbc.BinaryData{} struct for variable-size elements (strings/binaries).
template <typename OffsetT>
ERL_NIF_TERM make_binary_data(ErlNifEnv *env, struct ArrowArray * values, int64_t offset, int64_t count, int64_t offset_buffer_index, int64_t data_buffer_index, int64_t bitmap_buffer_index, void* resource) {
    const OffsetT * offsets_ptr = (const OffsetT *)values->buffers[offset_buffer_index];
    const uint8_t * data_ptr = (const uint8_t *)values->buffers[data_buffer_index];
    const uint8_t * validity_bitmap = (const uint8_t *)values->buffers[bitmap_buffer_index];

    ERL_NIF_TERM offsets_term = enif_make_resource_binary(env, resource, &offsets_ptr[offset], (count + 1) * sizeof(OffsetT));

    OffsetT data_start = offsets_ptr[offset];
    OffsetT data_end = offsets_ptr[offset + count];
    ERL_NIF_TERM data_term = enif_make_resource_binary(env, resource, data_ptr + data_start, data_end - data_start);

    ERL_NIF_TERM validity_term;
    ERL_NIF_TERM offset_term = enif_make_int(env, (int)offset);
    if (validity_bitmap == nullptr) {
        validity_term = kAtomNil;
    } else {
        size_t total_bitmap_bytes = (values->length + 7) / 8;
        validity_term = enif_make_resource_binary(env, resource, validity_bitmap, total_bitmap_bytes);
    }

    std::vector<ERL_NIF_TERM> keys = {
        kAtomStructKey,
        kAtomOffsets,
        kAtomDataKey,
        kAtomValidity,
        kAtomBitOffsetKey,
    };
    std::vector<ERL_NIF_TERM> vals = {
        kAtomAdbcBinaryDataModule,
        offsets_term,
        data_term,
        validity_term,
        offset_term,
    };

    ERL_NIF_TERM binary_data;
    enif_make_map_from_arrays(env, keys.data(), vals.data(), (unsigned)vals.size(), &binary_data);
    return binary_data;
}

// Build an %Adbc.BufferData{} struct for fixed-size elements.
ERL_NIF_TERM make_buffer_data(ErlNifEnv *env, struct ArrowArray * values, int64_t offset, int64_t count, size_t element_bytes, int64_t data_buffer_index, int64_t bitmap_buffer_index, void* resource) {
    const uint8_t * value_buffer = (const uint8_t *)values->buffers[data_buffer_index];
    const uint8_t * validity_bitmap = (const uint8_t *)values->buffers[bitmap_buffer_index];
    size_t data_size = element_bytes * count;
    const void * data_ptr = &value_buffer[element_bytes * offset];

    ERL_NIF_TERM data_binary = enif_make_resource_binary(env, resource, data_ptr, data_size);

    ERL_NIF_TERM validity_term;
    int bit_offset;
    slice_validity_bitmap(env, validity_bitmap, offset, count, resource, validity_term, bit_offset);

    std::vector<ERL_NIF_TERM> keys = {
        kAtomStructKey,
        kAtomDataKey,
        kAtomValidity,
        kAtomBitOffsetKey,
    };
    std::vector<ERL_NIF_TERM> vals = {
        kAtomAdbcBufferDataModule,
        data_binary,
        validity_term,
        enif_make_int(env, bit_offset),
    };

    ERL_NIF_TERM buffer_data;
    enif_make_map_from_arrays(env, keys.data(), vals.data(), (unsigned)vals.size(), &buffer_data);
    return buffer_data;
}

int arrow_array_to_nif_term(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, int64_t offset, int64_t count, int64_t level, std::vector<ERL_NIF_TERM> &out_terms, ERL_NIF_TERM &term_type, ERL_NIF_TERM &arrow_metadata, ERL_NIF_TERM &error, bool skip_dictionary_check, void* resource) {
    if (schema == nullptr) {
        error = erlang::nif::error(env, "invalid ArrowSchema (nullptr) when invoking next");
        return 1;
    }
    if (values == nullptr) {
        error = erlang::nif::error(env, "invalid ArrowArray (nullptr) when invoking next");
        return 1;
    }

    char err_msg_buf[256] = { '\0' };
    const char* format = schema->format ? schema->format : "";
    const char* name = schema->name ? schema->name : "";
    ERL_NIF_TERM current_term{}, children_term{};
    size_t format_len = strlen(format);
    size_t element_bytes = 0;

    term_type = kAtomNil;
    std::vector<ERL_NIF_TERM> children;

    constexpr int64_t bitmap_buffer_index = 0;
    int64_t data_buffer_index = 1;
    int64_t offset_buffer_index = 2;

    NANOARROW_RETURN_NOT_OK(arrow_metadata_to_nif_term(env, schema->metadata, &arrow_metadata));

    if (!skip_dictionary_check) {
        if (schema->dictionary != nullptr && values->dictionary != nullptr) {
            // NANOARROW_TYPE_DICTIONARY
            //
            // For dictionary-encoded arrays, the ArrowSchema.format string
            // encodes the index type. The dictionary value type can be read
            // from the ArrowSchema.dictionary structure.
            //
            // The same holds for ArrowArray structure: while the parent
            // structure points to the index data, the ArrowArray.dictionary
            // points to the dictionary values array.
            term_type = kAdbcColumnTypeDictionary;

            if (get_arrow_dictionary(env, schema, values, schema->dictionary, values->dictionary, offset, count, level, children, error, resource) == 1) {
                return 1;
            }
            out_terms.emplace_back(erlang::nif::make_binary(env, name));
            out_terms.emplace_back(children[0]);
            return 0;
        }
        if (schema->dictionary != nullptr && values->dictionary == nullptr) {
            error = erlang::nif::error(env, "invalid ArrowArray (dictionary), values->dictionary == nullptr");
            return 1;
        }
        if (schema->dictionary == nullptr && values->dictionary != nullptr) {
            error = erlang::nif::error(env, "invalid ArrowArray (dictionary), schema->dictionary == nullptr");
            return 1;
        }
    }

    bool is_struct = false;
    bool format_processed = true;
    if (format_len == 1) {
        if (format[0] == 'n') {
            term_type = kAtomNil;
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            std::vector<ERL_NIF_TERM> nils(count);
            for (int64_t i = offset; i < offset + count; i++) {
                nils.push_back(kAtomNil);
            }
            current_term = kAtomNil;
        } else if (format[0] == 'l') {
            term_type = kAdbcColumnTypeS64;
            element_bytes = 8;
        } else if (format[0] == 'c') {
            term_type = kAdbcColumnTypeS8;
            element_bytes = 1;
        } else if (format[0] == 's') {
            term_type = kAdbcColumnTypeS16;
            element_bytes = 2;
        } else if (format[0] == 'i') {
            term_type = kAdbcColumnTypeS32;
            element_bytes = 4;
        } else if (format[0] == 'L') {
            term_type = kAdbcColumnTypeU64;
            element_bytes = 8;
        } else if (format[0] == 'C') {
            term_type = kAdbcColumnTypeU8;
            element_bytes = 1;
        } else if (format[0] == 'S') {
            term_type = kAdbcColumnTypeU16;
            element_bytes = 2;
        } else if (format[0] == 'I') {
            term_type = kAdbcColumnTypeU32;
            element_bytes = 4;
        }

        if (element_bytes > 0) {
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (values->n_buffers != 2) {
                snprintf(err_msg_buf, 255, "invalid n_buffers value for ArrowArray (format=%s), values->n_buffers != 2", schema->format);
                error = erlang::nif::error(env, erlang::nif::make_binary(env, err_msg_buf));
                return 1;
            }
            current_term = make_buffer_data(env, values, offset, count, element_bytes, data_buffer_index, bitmap_buffer_index, resource);
        } else if (format[0] == 'e') {
            // NANOARROW_TYPE_HALF_FLOAT
            term_type = kAdbcColumnTypeF16;
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (values->n_buffers != 2) {
                error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=e), values->n_buffers != 2");
                return 1;
            }
            current_term = make_buffer_data(env, values, offset, count, sizeof(uint16_t), data_buffer_index, bitmap_buffer_index, resource);
        } else if (format[0] == 'f') {
            // NANOARROW_TYPE_FLOAT
            term_type = kAdbcColumnTypeF32;
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (values->n_buffers != 2) {
                error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=f), values->n_buffers != 2");
                return 1;
            }
            current_term = make_buffer_data(env, values, offset, count, sizeof(float), data_buffer_index, bitmap_buffer_index, resource);
        } else if (format[0] == 'g') {
            // NANOARROW_TYPE_DOUBLE
            term_type = kAdbcColumnTypeF64;
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (values->n_buffers != 2) {
                error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=g), values->n_buffers != 2");
                return 1;
            }
            current_term = make_buffer_data(env, values, offset, count, sizeof(double), data_buffer_index, bitmap_buffer_index, resource);
        } else if (format[0] == 'b') {
            // NANOARROW_TYPE_BOOL
            using value_type = bool;
            term_type = kAdbcColumnTypeBool;
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (values->n_buffers != 2) {
                error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=b), values->n_buffers != 2");
                return 1;
            }
            {
                const uint8_t * data_buf = (const uint8_t *)values->buffers[data_buffer_index];
                size_t total_data_bytes = (values->length + 7) / 8;
                ERL_NIF_TERM data_term = enif_make_resource_binary(env, resource, data_buf, total_data_bytes);

                const uint8_t * validity_bitmap = (const uint8_t *)values->buffers[bitmap_buffer_index];
                ERL_NIF_TERM validity_term;
                int bit_offset_val;
                slice_validity_bitmap(env, validity_bitmap, offset, count, resource, validity_term, bit_offset_val);

                std::vector<ERL_NIF_TERM> keys = {
                    kAtomStructKey, kAtomDataKey, kAtomValidity, kAtomBitOffsetKey, kAtomSizeKey,
                };
                std::vector<ERL_NIF_TERM> vals = {
                    kAtomAdbcBufferDataModule, data_term, validity_term, enif_make_int(env, (int)offset), enif_make_int64(env, count),
                };
                enif_make_map_from_arrays(env, keys.data(), vals.data(), (unsigned)vals.size(), &current_term);
            }
        } else if (format[0] == 'u' || format[0] == 'z') {
            // NANOARROW_TYPE_BINARY
            // NANOARROW_TYPE_STRING
            if (format[0] == 'z') {
                term_type = kAdbcColumnTypeBinary;
            } else {
                term_type = kAdbcColumnTypeString;
            }
            offset_buffer_index = 1;
            data_buffer_index = 2;
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (values->n_buffers != 3) {
                error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=u or format=z), values->n_buffers != 3");
                return 1;
            }
            current_term = make_binary_data<int32_t>(env, values, offset, count, offset_buffer_index, data_buffer_index, bitmap_buffer_index, resource);
        } else if (format[0] == 'U' || format[0] == 'Z') {
            // NANOARROW_TYPE_LARGE_STRING
            // NANOARROW_TYPE_LARGE_BINARY
            if (format[0] == 'Z') {
                term_type = kAdbcColumnTypeLargeBinary;
            } else {
                term_type = kAdbcColumnTypeLargeString;
            }
            offset_buffer_index = 1;
            data_buffer_index = 2;
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (values->n_buffers != 3) {
                error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=U or format=Z), values->n_buffers != 3");
                return 1;
            }
            current_term = make_binary_data<int64_t>(env, values, offset, count, offset_buffer_index, data_buffer_index, bitmap_buffer_index, resource);
        } else {
            format_processed = false;
        }
    } else if (format_len == 2) {
        if (strncmp("+s", format, 2) == 0) {
            // NANOARROW_TYPE_STRUCT
            is_struct = true;
            term_type = kAdbcColumnTypeStruct;

            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            if (get_arrow_struct(env, schema, values, offset, count, level, children, error, resource) == 1) {
                return 1;
            }
            children_term = enif_make_list_from_array(env, children.data(), (unsigned)children.size());
        } else if (strncmp("+r", format, 2) == 0) {
            // NANOARROW_TYPE_RUN_END_ENCODED (maybe in nanoarrow v0.6.0)
            // https://github.com/apache/arrow-nanoarrow/pull/507
            term_type = kAdbcColumnTypeRunEndEncoded;
            children_term = get_arrow_run_end_encoded(env, schema, values, offset, count, level, resource);
        } else if (strncmp("+m", format, 2) == 0) {
            // NANOARROW_TYPE_MAP
            term_type = kAdbcColumnTypeMap;
            children_term = get_arrow_array_map_children(env, schema, values, offset, count, level, resource);
        } else if (strncmp("+l", format, 2) == 0) {
            // NANOARROW_TYPE_LIST
            term_type = kAdbcColumnTypeList;
            children_term = get_arrow_array_list_children(env, schema, values, offset, count, level, NANOARROW_TYPE_LIST, 0, resource);
        } else if (strncmp("+L", format, 2) == 0) {
            // NANOARROW_TYPE_LARGE_LIST
            term_type = kAdbcColumnTypeLargeList;
            children_term = get_arrow_array_list_children(env, schema, values, offset, count, level, NANOARROW_TYPE_LARGE_LIST, 0, resource);
        } else if (strncmp("vu", format, 2) == 0 || strncmp("vz", format, 2) == 0) {
            // NANOARROW_TYPE_STRING_VIEW
            // NANOARROW_TYPE_BINARY_VIEW
            if (format[1] == 'u') {
                term_type = kAdbcColumnTypeStringView;
            } else {
                term_type = kAdbcColumnTypeBinaryView;
            }
            if (count == -1) count = values->length;
            if (count > values->length) count = values->length - offset;
            // Buffer layout: validity bitmap (0), views buffer (1), data buffers (2..n_buffers-1)
            if (values->n_buffers < 2) {
                error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=vu or format=vz), values->n_buffers < 2");
                return 1;
            }
            int64_t n_data_buffers = values->n_buffers - 2;
            current_term = string_views_from_buffer(
                env,
                offset,
                count,
                (const uint8_t*)values->buffers[bitmap_buffer_index],
                (const uint8_t*)values->buffers[1],
                n_data_buffers,
                (const uint8_t* const*)(values->buffers + 2)
            );
        } else {
            format_processed = false;
        }
    } else if (format_len >= 3) {
        // handle all formats that start with `t` (temporal types)
        if (format[0] == 't') {
            // formats for timestamp can be 3 or more
            // lets handle timestamps after this `if` block
            // (tdX, ttX, tDX and tiX are in this block)
            if (format_len == 3) {
                if (format[1] == 'd') {
                    // possible format strings:
                    // tdD - date32 [days]
                    // tdm - date64 [milliseconds]
                    char unit = format[2];

                    if (unit == 'D' || unit == 'm') {
                        // NANOARROW_TYPE_DATE32
                        // NANOARROW_TYPE_DATE64
                        size_t element_bytes;
                        if (unit == 'D') {
                            term_type = kAdbcColumnTypeDate32;
                            element_bytes = 4;
                        } else {
                            term_type = kAdbcColumnTypeDate64;
                            element_bytes = 8;
                        }
                        if (count == -1) count = values->length;
                        if (count > values->length) count = values->length - offset;
                        if (values->n_buffers != 2) {
                            snprintf(err_msg_buf, 255, "invalid n_buffers value for ArrowArray (format=%s), values->n_buffers != 2", schema->format);
                            error = erlang::nif::error(env, erlang::nif::make_binary(env, err_msg_buf));
                            return 1;
                        }
                        current_term = make_buffer_data(env, values, offset, count, element_bytes, data_buffer_index, bitmap_buffer_index, resource);
                    } else {
                        format_processed = false;
                    }
                // time
                } else if (format[1] == 't') {
                    // possible format strings:
                    // tts - time32 [seconds]
                    // ttm - time32 [milliseconds]
                    // ttu - time64 [microseconds]
                    // ttn - time64 [nanoseconds]
                    switch (format[2]) {
                        case 's': // seconds
                            term_type = kAdbcColumnTypeTime32Seconds;
                            break;
                        case 'm': // milliseconds
                            term_type = kAdbcColumnTypeTime32Milliseconds;
                            break;
                        case 'u': // microseconds
                            term_type = kAdbcColumnTypeTime64Microseconds;
                            break;
                        case 'n': // nanoseconds
                            term_type = kAdbcColumnTypeTime64Nanoseconds;
                            break;
                        default:
                            format_processed = false;
                    }

                    if (format_processed) {
                        if (count == -1) count = values->length;
                        if (count > values->length) count = values->length - offset;
                        if (values->n_buffers != 2) {
                            error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=tt), values->n_buffers != 2");
                            return 1;
                        }

                        size_t element_bytes = (format[2] == 's' || format[2] == 'm') ? 4 : 8;
                        current_term = make_buffer_data(env, values, offset, count, element_bytes, data_buffer_index, bitmap_buffer_index, resource);
                    }
                // timestamp
                } else if (format[1] == 'D') {
                    // possible format strings:
                    // tDs - duration [seconds]
                    // tDm - duration [milliseconds]
                    // tDu - duration [microseconds]
                    // tDn - duration [nanoseconds]

                    // NANOARROW_TYPE_DURATION
                    switch (format[2]) {
                        case 's': // seconds
                            term_type = kAdbcColumnTypeDurationSeconds;
                            break;
                        case 'm': // milliseconds
                            term_type = kAdbcColumnTypeDurationMilliseconds;
                            break;
                        case 'u': // microseconds
                            term_type = kAdbcColumnTypeDurationMicroseconds;
                            break;
                        case 'n': // nanoseconds
                            term_type = kAdbcColumnTypeDurationNanoseconds;
                            break;
                        default:
                            format_processed = false;
                    }

                    if (format_processed) {
                        if (count == -1) count = values->length;
                        if (count > values->length) count = values->length - offset;
                        if (values->n_buffers != 2) {
                            error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=tD), values->n_buffers != 2");
                            return 1;
                        }

                        current_term = make_buffer_data(env, values, offset, count, 8, data_buffer_index, bitmap_buffer_index, resource);
                    }
                } else if (format[1] == 'i') {
                    // possible format strings:
                    // tiM - interval [months]
                    // tiD - interval [days, time]
                    // tin - interval [month, day, nanoseconds]

                    // NANOARROW_TYPE_INTERVAL
                    switch (format[2]) {
                        case 'M': // months
                            term_type = kAdbcColumnTypeIntervalMonth;
                            break;
                        case 'D': // days, time
                            term_type = kAdbcColumnTypeIntervalDayTime;
                            break;
                        case 'n': // month, day, nanoseconds
                            term_type = kAdbcColumnTypeIntervalMonthDayNano;
                            break;
                        default:
                            format_processed = false;
                    }

                    if (format_processed) {
                        size_t element_bytes;
                        if (format[2] == 'M') {
                            element_bytes = 4;
                        } else if (format[2] == 'D') {
                            element_bytes = 8;
                        } else {
                            element_bytes = 16;
                        }
                        if (count == -1) count = values->length;
                        if (count > values->length) count = values->length - offset;
                        if (values->n_buffers != 2) {
                            snprintf(err_msg_buf, 255, "invalid n_buffers value for ArrowArray (format=%s), values->n_buffers != 2", schema->format);
                            error = erlang::nif::error(env, erlang::nif::make_binary(env, err_msg_buf));
                            return 1;
                        }
                        current_term = make_buffer_data(env, values, offset, count, element_bytes, data_buffer_index, bitmap_buffer_index, resource);
                    }
                } else {
                    format_processed = false;
                }
            } else if (format_len >= 4 && format[1] == 's' && format[3] == ':') {
                // according to the arrow spec:
                //   The timezone string is appended as-is after the colon character :,
                //   without any quotes. If the timezone is empty, the colon : must still be included.
                // so the format length for timestamps must be >= 4

                // possible format strings:
                // tss: - timestamp [seconds]
                // tsm: - timestamp [milliseconds]
                // tsu: - timestamp [microseconds]
                // tsn: - timestamp [nanoseconds]
                //
                // if there're any timezone infomation
                // it should be in the format like `tsu:timezone`

                // NANOARROW_TYPE_TIMESTAMP
                ERL_NIF_TERM term_unit;
                ERL_NIF_TERM term_timezone = kAtomNil;
                switch (format[2]) {
                    case 's': // seconds
                        term_unit = kAtomSeconds;
                        break;
                    case 'm': // milliseconds
                        term_unit = kAtomMilliseconds;
                        break;
                    case 'u': // microseconds
                        term_unit = kAtomMicroseconds;
                        break;
                    case 'n': // nanoseconds
                        term_unit = kAtomNanoseconds;
                        break;
                    default:
                        format_processed = false;
                }

                if (format_processed) {
                    if (format_len > 4 && format[3] == ':') {
                        std::string timezone(&format[4]);
                        term_timezone = erlang::nif::make_binary(env, timezone);
                    }
                    term_type = enif_make_tuple3(env, kAtomTimestamp, term_unit, term_timezone);

                    if (count == -1) count = values->length;
                    if (count > values->length) count = values->length - offset;
                    if (values->n_buffers != 2) {
                        error = erlang::nif::error(env, "invalid n_buffers value for ArrowArray (format=ts), values->n_buffers != 2");
                        return 1;
                    }

                    current_term = make_buffer_data(env, values, offset, count, 8, data_buffer_index, bitmap_buffer_index, resource);
                }
            } else {
                format_processed = false;
            }
        } else {
            if (format_len == 3 && strncmp("+vl", format, 3) == 0) {
                // NANOARROW_TYPE_LIST(VIEW)
                term_type = kAdbcColumnTypeListView;
                children_term = get_arrow_array_list_view(env, schema, values, offset, count, level, NANOARROW_TYPE_LIST, resource);
            } else if (format_len == 3 && strncmp("+vL", format, 3) == 0) {
                // NANOARROW_TYPE_LARGE_LIST(VIEW)
                term_type = kAdbcColumnTypeLargeListView;
                children_term = get_arrow_array_list_view(env, schema, values, offset, count, level, NANOARROW_TYPE_LARGE_LIST, resource);
            } else if (strncmp("+w:", format, 3) == 0) {
                // NANOARROW_TYPE_FIXED_SIZE_LIST
                unsigned n_items = 0;
                for (size_t i = 3; i < format_len; i++) {
                    n_items = n_items * 10 + (format[i] - '0');
                }
                term_type = kAtomFixedSizeList;
                children_term = get_arrow_array_list_children(env, schema, values, offset, count, level, NANOARROW_TYPE_FIXED_SIZE_LIST, n_items, resource);
            } else if (strncmp("w:", format, 2) == 0) {
                // NANOARROW_TYPE_FIXED_SIZE_BINARY
                if (count == -1) count = values->length;
                if (count > values->length) count = values->length - offset;
                if (values->n_buffers != 2) {
                    snprintf(err_msg_buf, 255, "invalid n_buffers value for ArrowArray (format=%s), values->n_buffers != 2", schema->format);
                    error = erlang::nif::error(env, erlang::nif::make_binary(env, err_msg_buf));
                    return 1;
                }
                size_t nbytes = 0;
                for (size_t i = 2; i < format_len; i++) {
                    nbytes = nbytes * 10 + (format[i] - '0');
                }
                term_type = kAdbcColumnTypeFixedSizeBinary(nbytes);
                current_term = make_buffer_data(env, values, offset, count, nbytes, data_buffer_index, bitmap_buffer_index, resource);
            } else if (format_len > 4 && (strncmp("+ud:", format, 4) == 0)) {
                // NANOARROW_TYPE_DENSE_UNION
                term_type = kAdbcColumnTypeDenseUnion;
                children_term = get_arrow_array_dense_union_children(env, schema, values, offset, count, level, resource);
            } else if (format_len > 4 && (strncmp("+us:", format, 4) == 0)) {
                // NANOARROW_TYPE_SPARSE_UNION
                term_type = kAdbcColumnTypeSparseUnion;
                children_term = get_arrow_array_sparse_union_children(env, schema, values, offset, count, level, resource);
            } else if (strncmp("d:", format, 2) == 0) {
                // NANOARROW_TYPE_DECIMAL128
                // NANOARROW_TYPE_DECIMAL256
                //
                // format should match `d:P,S[,N]`
                // where P is precision, S is scale, N is bits
                // N is optional and defaults to 128
                int precision = 0;
                int scale = 0;
                int bits = 0;
                int * d[3] = {&precision, &scale, &bits};
                int index = 0;
                for (size_t i = 2; i < format_len; i++) {
                    if (format[i] == ',') {
                        if (index < 2) {
                            index++;
                        } else {
                            format_processed = false;
                            break;
                        }
                        continue;
                    }

                    *d[index] = *d[index] * 10 + (format[i] - '0');
                }

                if (format_processed) {
                    if (bits == 0) bits = 128;
                    term_type = (bits == 128)
                        ? kAdbcColumnTypeDecimal128(precision, scale)
                        : kAdbcColumnTypeDecimal256(precision, scale);
                    if (count == -1) count = values->length;
                    if (count > values->length) count = values->length - offset;
                    if (values->n_buffers != 2) {
                        snprintf(err_msg_buf, 255, "invalid n_buffers value for ArrowArray (format=%s), values->n_buffers != 2", schema->format);
                        error = erlang::nif::error(env, erlang::nif::make_binary(env, err_msg_buf));
                        return 1;
                    }
                    {
                        size_t element_bytes = bits / 8;
                        current_term = make_buffer_data(env, values, offset, count, element_bytes, data_buffer_index, bitmap_buffer_index, resource);
                    }
                }
            } else {
                format_processed = false;
            }
        }
    } else {
        format_processed = false;
    }

    if (!format_processed) {
        snprintf(err_msg_buf, sizeof(err_msg_buf)/sizeof(err_msg_buf[0]), "not yet implemented for format: `%s`", schema->format);
        error = erlang::nif::error(env, erlang::nif::make_binary(env, err_msg_buf));
        return 1;
        // printf("not implemented for format: `%s`\r\n", schema->format);
        // printf("length: %lld\r\n", values->length);
        // printf("null_count: %lld\r\n", values->null_count);
        // printf("offset: %lld\r\n", values->offset);
        // printf("n_buffers: %lld\r\n", values->n_buffers);
        // printf("n_children: %lld\r\n", values->n_children);
        // printf("buffers: %p\r\n", values->buffers);
    }

    out_terms.clear();
    if (is_struct) {
        if (level > 0) {
            out_terms.emplace_back(erlang::nif::make_binary(env, name));
        }
        out_terms.emplace_back(children_term);
    } else {
        if (schema->children) {
            out_terms.emplace_back(erlang::nif::make_binary(env, name));
            out_terms.emplace_back(children_term);
        } else {
            out_terms.emplace_back(erlang::nif::make_binary(env, name));
            out_terms.emplace_back(current_term);
        }
    }

    return 0;
}

int arrow_array_to_nif_term(ErlNifEnv *env, struct ArrowSchema * schema, struct ArrowArray * values, uint64_t level, std::vector<ERL_NIF_TERM> &out_terms, ERL_NIF_TERM &out_type, ERL_NIF_TERM &metadata, ERL_NIF_TERM &error, bool skip_dictionary_check, void* resource) {
    return arrow_array_to_nif_term(env, schema, values, 0, -1, level, out_terms, out_type, metadata, error, skip_dictionary_check, resource);
}

#endif  // ADBC_ARROW_ARRAY_HPP
