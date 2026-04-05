#pragma once

#include <arrow-adbc/adbc.h>
#include <cstdbool>
#include <cstdint>
#include <erl_nif.h>
#include <nanoarrow/nanoarrow.hpp>
#include <time.h>

#include "shared.hpp"

namespace adbc_nif {

static void column_to_arrow(ErlNifEnv *env, ExAdbcField &field, fine::Term data,
                            struct ArrowArray *array_out,
                            struct ArrowSchema *schema_out);

// Copy a validity bitmap into an Arrow array, handling arbitrary bit_offset.
// When bit_offset is byte-aligned, uses bulk memcpy. Otherwise falls back to
// per-bit copy.
static void copy_validity_bitmap(const uint8_t *src, int bit_offset,
                                 size_t count, struct ArrowArray *write_array) {
  struct ArrowBuffer *validity_buffer = ArrowArrayBuffer(write_array, 0);
  size_t validity_bytes = (count + 7) / 8;
  NANOARROW_THROW_NOT_OK(ArrowBufferReserve(validity_buffer, validity_bytes));

  if (bit_offset % 8 == 0) {
    size_t bitmap_start = bit_offset / 8;
    NANOARROW_THROW_NOT_OK(
        ArrowBufferAppend(validity_buffer, src + bitmap_start, validity_bytes));
    write_array->null_count =
        count - ArrowBitCountSet(src + bitmap_start, 0, count);
  } else {
    size_t src_bit = bit_offset;
    size_t valid_count = 0;
    for (size_t dst_byte = 0; dst_byte < validity_bytes; dst_byte++) {
      uint8_t byte = 0;
      size_t bits_in_byte =
          (dst_byte == validity_bytes - 1 && count % 8 != 0) ? count % 8 : 8;
      for (size_t b = 0; b < bits_in_byte; b++) {
        if (ArrowBitGet(src, src_bit)) {
          byte |= (uint8_t)(1 << b);
          valid_count++;
        }
        src_bit++;
      }
      NANOARROW_THROW_NOT_OK(ArrowBufferAppendInt8(validity_buffer, byte));
    }
    write_array->null_count = count - valid_count;
  }
}

static void get_buffer_data(ErlNifEnv *env, ERL_NIF_TERM data_term,
                            size_t element_bytes, struct ArrowArray *array_out,
                            struct ArrowSchema *schema_out) {
  struct ArrowError arrow_error{};
  nanoarrow::UniqueArray tmp;
  struct ArrowArray *write_array = tmp.get();
  if (ArrowArrayInitFromSchema(write_array, schema_out, &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
  NANOARROW_THROW_NOT_OK(ArrowArrayStartAppending(write_array));

  ExAdbcBufferData buf = fine::decode<ExAdbcBufferData>(env, data_term);

  ErlNifBinary data_bin = fine::decode<ErlNifBinary>(env, buf.data);

  if (data_bin.size % element_bytes != 0) {
    throw std::invalid_argument(
        "buffer data size is not a multiple of element size");
  }
  size_t count = data_bin.size / element_bytes;

  NANOARROW_THROW_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 1),
                                           data_bin.data, data_bin.size));

  if (buf.validity) {
    ErlNifBinary validity_bin = fine::decode<ErlNifBinary>(env, *buf.validity);
    copy_validity_bitmap(validity_bin.data, buf.bit_offset, count, write_array);
  }

  write_array->length = count;

  if (ArrowArrayFinishBuildingDefault(tmp.get(), &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
  ArrowArrayMove(tmp.get(), array_out);
}

static void get_dictionary(ErlNifEnv *env, ERL_NIF_TERM type_term,
                           ERL_NIF_TERM batches_list,
                           struct ArrowArray *array_out,
                           struct ArrowSchema *schema_out) {
  // type_term is {:dictionary, key_field, value_field}
  int arity;
  const ERL_NIF_TERM *tuple_elems;
  if (!enif_get_tuple(env, type_term, &arity, &tuple_elems) || arity != 3) {
    throw std::invalid_argument(
        "Expected dictionary type to be {:dictionary, key_field, value_field}");
  }
  ERL_NIF_TERM key_field_map = tuple_elems[1];
  ERL_NIF_TERM value_field_map = tuple_elems[2];

  // data is a %Adbc.DictionaryData{key: data, value: data}
  ExAdbcDictionaryData dict_data =
      fine::decode<ExAdbcDictionaryData>(env, batches_list);
  ExAdbcField keys_field = fine::decode<ExAdbcField>(env, key_field_map);
  ExAdbcField values_field = fine::decode<ExAdbcField>(env, value_field_map);

  column_to_arrow(env, keys_field, dict_data.key, array_out, schema_out);

  NANOARROW_THROW_NOT_OK(ArrowSchemaAllocateDictionary(schema_out));
  NANOARROW_THROW_NOT_OK(ArrowArrayAllocateDictionary(array_out));

  column_to_arrow(env, values_field, dict_data.value, array_out->dictionary,
                  schema_out->dictionary);
}

static void get_list_string(ErlNifEnv *env, ERL_NIF_TERM list,
                            ArrowType nanoarrow_type,
                            struct ArrowArray *array_out,
                            struct ArrowSchema *schema_out) {
  struct ArrowError arrow_error{};
  NANOARROW_THROW_NOT_OK(ArrowSchemaSetType(schema_out, nanoarrow_type));

  size_t offset_size = (nanoarrow_type == NANOARROW_TYPE_LARGE_STRING ||
                        nanoarrow_type == NANOARROW_TYPE_LARGE_BINARY)
                           ? 8
                           : 4;

  nanoarrow::UniqueArray tmp;
  struct ArrowArray *write_array = tmp.get();
  if (ArrowArrayInitFromSchema(write_array, schema_out, &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }

  // list is an %Adbc.BinaryData{offsets, data, validity | nil, bit_offset}
  // Buffers: 0 = validity, 1 = offsets, 2 = data
  ExAdbcBinaryData bin_data = fine::decode<ExAdbcBinaryData>(env, list);

  ErlNifBinary offsets_bin = fine::decode<ErlNifBinary>(env, bin_data.offsets);
  ErlNifBinary data_bin = fine::decode<ErlNifBinary>(env, bin_data.data);

  if (offsets_bin.size < offset_size) {
    throw std::invalid_argument("offsets binary too small");
  }
  size_t count = (offsets_bin.size / offset_size) - 1;

  NANOARROW_THROW_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 1),
                                           offsets_bin.data, offsets_bin.size));
  NANOARROW_THROW_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 2),
                                           data_bin.data, data_bin.size));

  if (bin_data.validity) {
    ErlNifBinary validity_bin =
        fine::decode<ErlNifBinary>(env, *bin_data.validity);
    copy_validity_bitmap(validity_bin.data, bin_data.bit_offset, count,
                         write_array);
  }

  write_array->length = count;
  if (ArrowArrayFinishBuildingDefault(tmp.get(), &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
  ArrowArrayMove(tmp.get(), array_out);
}

static void get_boolean_data(ErlNifEnv *env, ERL_NIF_TERM data_term,
                             ArrowType nanoarrow_type,
                             struct ArrowArray *array_out,
                             struct ArrowSchema *schema_out) {
  struct ArrowError arrow_error{};
  NANOARROW_THROW_NOT_OK(ArrowSchemaSetType(schema_out, nanoarrow_type));

  ExAdbcBooleanData bool_data = fine::decode<ExAdbcBooleanData>(env, data_term);

  nanoarrow::UniqueArray tmp;
  struct ArrowArray *write_array = tmp.get();
  if (ArrowArrayInitFromSchema(write_array, schema_out, &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }

  ErlNifBinary data_bin = fine::decode<ErlNifBinary>(env, bool_data.data);

  // Copy data bitmap (buffer 1)
  NANOARROW_THROW_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(write_array, 1),
                                           data_bin.data, data_bin.size));

  if (bool_data.validity) {
    ErlNifBinary validity_bin =
        fine::decode<ErlNifBinary>(env, *bool_data.validity);
    copy_validity_bitmap(validity_bin.data, bool_data.bit_offset,
                         bool_data.size, write_array);
  }

  write_array->length = bool_data.size;
  if (ArrowArrayFinishBuildingDefault(tmp.get(), &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
  ArrowArrayMove(tmp.get(), array_out);
}

static void get_struct(ErlNifEnv *env, ERL_NIF_TERM type_term,
                       ERL_NIF_TERM data_term, struct ArrowArray *array_out,
                       struct ArrowSchema *schema_out) {
  // type_term is {:struct, [%Adbc.Field{}, ...]}
  // data_term is %Adbc.StructData{validity: binary|nil, bit_offset: int,
  // values: [child_data, ...]}
  struct ArrowError arrow_error{};

  int arity;
  const ERL_NIF_TERM *tuple_elems;
  if (!enif_get_tuple(env, type_term, &arity, &tuple_elems) || arity != 2) {
    throw std::invalid_argument("struct type must be {:struct, [fields]}");
  }
  ERL_NIF_TERM fields_list = tuple_elems[1];

  ExAdbcStructData struct_data = fine::decode<ExAdbcStructData>(env, data_term);

  unsigned n_children = 0;
  if (!enif_get_list_length(env, fields_list, &n_children) || n_children == 0) {
    throw std::invalid_argument("struct type must have at least one field");
  }

  NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeStruct(schema_out, n_children));

  // Build each child into its schema slot and collect child arrays
  std::vector<nanoarrow::UniqueArray> child_arrays(n_children);
  ERL_NIF_TERM field_head, field_tail = fields_list;
  ERL_NIF_TERM value_head, value_tail = struct_data.values;

  for (unsigned i = 0; i < n_children; i++) {
    if (!enif_get_list_cell(env, field_tail, &field_head, &field_tail) ||
        !enif_get_list_cell(env, value_tail, &value_head, &value_tail)) {
      throw std::invalid_argument(
          "struct fields and values lists have different lengths");
    }

    ExAdbcField child_field = fine::decode<ExAdbcField>(env, field_head);

    if (schema_out->children[i]->release) {
      schema_out->children[i]->release(schema_out->children[i]);
    }

    nanoarrow::UniqueSchema child_schema;
    column_to_arrow(env, child_field, value_head, child_arrays[i].get(),
                    child_schema.get());
    child_schema.move(schema_out->children[i]);
  }

  // Init array from the fully-populated schema
  if (ArrowArrayInitFromSchema(array_out, schema_out, &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
  NANOARROW_THROW_NOT_OK(ArrowArrayStartAppending(array_out));

  int64_t child_length = (n_children > 0) ? child_arrays[0].get()->length : 0;
  for (unsigned i = 0; i < n_children; i++) {
    ArrowArrayMove(child_arrays[i].get(), array_out->children[i]);
  }

  // Apply struct-level validity bitmap
  if (struct_data.validity) {
    ErlNifBinary validity_bin =
        fine::decode<ErlNifBinary>(env, *struct_data.validity);
    copy_validity_bitmap(validity_bin.data, struct_data.bit_offset,
                         child_length, array_out);
  }

  array_out->length = child_length;
  if (ArrowArrayFinishBuildingDefault(array_out, &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
}

static void get_list(ErlNifEnv *env, ERL_NIF_TERM parent_type_term,
                     ERL_NIF_TERM list, ArrowType arrow_type,
                     int32_t fixed_size, struct ArrowArray *array_out,
                     struct ArrowSchema *schema_out) {
  struct ArrowError arrow_error{};
  if (arrow_type == NANOARROW_TYPE_FIXED_SIZE_LIST) {
    NANOARROW_THROW_NOT_OK(
        ArrowSchemaSetTypeFixedSize(schema_out, arrow_type, fixed_size));
  } else {
    NANOARROW_THROW_NOT_OK(ArrowSchemaSetType(schema_out, arrow_type));
  }

  // Extract inner field from parent type: {:list, inner_field} or {:large_list,
  // inner_field} or {:fixed_size_list, inner_field, size}
  ExAdbcField inner_field;
  {
    int arity;
    const ERL_NIF_TERM *tuple_elems;
    if (!enif_get_tuple(env, parent_type_term, &arity, &tuple_elems) ||
        arity < 2) {
      throw std::invalid_argument(
          "list type must be {:list, %Adbc.Field{}} with inner type info");
    }
    inner_field = fine::decode<ExAdbcField>(env, tuple_elems[1]);
  }

  // data is %Adbc.ListData{offsets: binary, validity: binary|nil, values: data,
  // bit_offset: int}
  ExAdbcListData list_data = fine::decode<ExAdbcListData>(env, list);

  // Build child array from the values list.
  // values is a list of child data items; iterate and process each
  // into the same child array via column_to_arrow.
  nanoarrow::UniqueArray child_array;
  nanoarrow::UniqueSchema child_schema;
  bool child_initialized = false;

  ERL_NIF_TERM val_head, val_tail = list_data.values;
  while (enif_get_list_cell(env, val_tail, &val_head, &val_tail)) {
    if (!child_initialized) {
      column_to_arrow(env, inner_field, val_head, child_array.get(),
                      child_schema.get());
      child_initialized = true;
    } else {
      nanoarrow::UniqueArray extra_array;
      nanoarrow::UniqueSchema extra_schema;
      column_to_arrow(env, inner_field, val_head, extra_array.get(),
                      extra_schema.get());

      // Append extra buffers into child array
      for (int64_t b = 0; b < extra_array.get()->n_buffers; b++) {
        struct ArrowBuffer *dst = ArrowArrayBuffer(child_array.get(), b);
        struct ArrowBuffer *src = ArrowArrayBuffer(extra_array.get(), b);
        if (src->size_bytes > 0) {
          NANOARROW_THROW_NOT_OK(
              ArrowBufferAppend(dst, src->data, src->size_bytes));
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
  child_schema.move(schema_out->children[0]);

  if (ArrowArrayInitFromSchema(array_out, schema_out, &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
  NANOARROW_THROW_NOT_OK(ArrowArrayStartAppending(array_out));

  // Move child array data into the parent's child slot
  ArrowArrayMove(child_array.get(), array_out->children[0]);

  // Determine element count from offsets binary
  size_t offset_elem_size = (arrow_type == NANOARROW_TYPE_LARGE_LIST) ? 8 : 4;
  ErlNifBinary offsets_bin = fine::decode<ErlNifBinary>(env, list_data.offsets);
  size_t n_elements = (offsets_bin.size / offset_elem_size) - 1;

  // Copy offsets into the list's offset buffer (buffer index 1).
  // Skip the first offset (0) since ArrowArrayStartAppending already wrote it.
  NANOARROW_THROW_NOT_OK(ArrowBufferAppend(
      ArrowArrayBuffer(array_out, 1), offsets_bin.data + offset_elem_size,
      offsets_bin.size - offset_elem_size));

  if (list_data.validity) {
    ErlNifBinary validity_bin =
        fine::decode<ErlNifBinary>(env, *list_data.validity);
    copy_validity_bitmap(validity_bin.data, list_data.bit_offset, n_elements,
                         array_out);
  }
  array_out->length = n_elements;

  if (ArrowArrayFinishBuildingDefault(array_out, &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
}

static void build_metadata_from_term(ErlNifEnv *env, ERL_NIF_TERM metadata_term,
                                     struct ArrowBuffer *metadata_buffer) {
  NANOARROW_THROW_NOT_OK(ArrowMetadataBuilderInit(metadata_buffer, nullptr));
  if (enif_is_map(env, metadata_term)) {
    ERL_NIF_TERM metadata_key, metadata_value;
    ErlNifMapIterator iter;
    enif_map_iterator_create(env, metadata_term, &iter,
                             ERL_NIF_MAP_ITERATOR_FIRST);
    while (enif_map_iterator_get_pair(env, &iter, &metadata_key,
                                      &metadata_value)) {
      ErlNifBinary key_bytes, value_bytes;
      struct ArrowStringView key_view{};
      struct ArrowStringView value_view{};
      if (enif_inspect_iolist_as_binary(env, metadata_key, &key_bytes)) {
        key_view.data = (const char *)key_bytes.data;
        key_view.size_bytes = static_cast<int64_t>(key_bytes.size);
      } else {
        ArrowBufferReset(metadata_buffer);
        enif_map_iterator_destroy(env, &iter);
        throw std::invalid_argument("cannot get metadata key");
      }
      if (enif_inspect_iolist_as_binary(env, metadata_value, &value_bytes)) {
        value_view.data = (const char *)value_bytes.data;
        value_view.size_bytes = static_cast<int64_t>(value_bytes.size);
      } else {
        ArrowBufferReset(metadata_buffer);
        enif_map_iterator_destroy(env, &iter);
        throw std::invalid_argument("cannot get metadata value");
      }

      NANOARROW_THROW_NOT_OK(
          ArrowMetadataBuilderAppend(metadata_buffer, key_view, value_view));
      enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);
  }
}

static std::optional<ArrowTimeUnit> atom_to_time_unit(fine::Atom unit) {
  if (unit == atoms::seconds) {
    return NANOARROW_TIME_UNIT_SECOND;
  } else if (unit == atoms::milliseconds) {
    return NANOARROW_TIME_UNIT_MILLI;
  } else if (unit == atoms::microseconds) {
    return NANOARROW_TIME_UNIT_MICRO;
  } else if (unit == atoms::nanoseconds) {
    return NANOARROW_TIME_UNIT_NANO;
  }
  return std::nullopt;
}

static void column_to_arrow(ErlNifEnv *env, ExAdbcField &field, fine::Term data,
                            struct ArrowArray *array_out,
                            struct ArrowSchema *schema_out) {
  std::string name = field.name.value_or("");

  // Derive nullable from the data's validity field rather than the Field
  // struct. If the data has a non-nil validity bitmap, the column is nullable.
  bool nullable = false;
  {
    ERL_NIF_TERM validity_term;
    if (enif_is_map(env, data) &&
        enif_get_map_value(env, data, fine::encode(env, atoms::validity),
                           &validity_term)) {
      nullable =
          !enif_is_identical(validity_term, fine::encode(env, atoms::nil));
    }
  }

  ArrowSchemaInit(schema_out);
  NANOARROW_THROW_NOT_OK(ArrowSchemaSetName(schema_out, name.c_str()));

  nanoarrow::UniqueBuffer metadata_buffer;
  build_metadata_from_term(env, field.metadata, metadata_buffer.get());
  NANOARROW_THROW_NOT_OK(
      ArrowSchemaSetMetadata(schema_out, (const char *)metadata_buffer->data));

  if (nullable) {
    schema_out->flags |= ARROW_FLAG_NULLABLE;
  } else {
    schema_out->flags &= ~ARROW_FLAG_NULLABLE;
  }

  // Data types can be found here:
  // https://arrow.apache.org/docs/format/CDataInterface.html
  using TypeVariant =
      std::variant<fine::Atom, std::tuple<fine::Atom, fine::Term>,
                   std::tuple<fine::Atom, fine::Term, fine::Term>>;

  auto decoded = fine::decode<TypeVariant>(env, field.type);

  if (auto *atom = std::get_if<fine::Atom>(&decoded)) {
    if (*atom == atoms::boolean) {
      return get_boolean_data(env, data, NANOARROW_TYPE_BOOL, array_out,
                              schema_out);
    } else if (*atom == atoms::s8) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_INT8));
      return get_buffer_data(env, data, 1, array_out, schema_out);
    } else if (*atom == atoms::u8) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_UINT8));
      return get_buffer_data(env, data, 1, array_out, schema_out);
    } else if (*atom == atoms::s16) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_INT16));
      return get_buffer_data(env, data, 2, array_out, schema_out);
    } else if (*atom == atoms::u16) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_UINT16));
      return get_buffer_data(env, data, 2, array_out, schema_out);
    } else if (*atom == atoms::s32) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_INT32));
      return get_buffer_data(env, data, 4, array_out, schema_out);
    } else if (*atom == atoms::u32) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_UINT32));
      return get_buffer_data(env, data, 4, array_out, schema_out);
    } else if (*atom == atoms::s64) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_INT64));
      return get_buffer_data(env, data, 8, array_out, schema_out);
    } else if (*atom == atoms::u64) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_UINT64));
      return get_buffer_data(env, data, 8, array_out, schema_out);
    } else if (*atom == atoms::f16) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_HALF_FLOAT));
      return get_buffer_data(env, data, 2, array_out, schema_out);
    } else if (*atom == atoms::f32) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_FLOAT));
      return get_buffer_data(env, data, 4, array_out, schema_out);
    } else if (*atom == atoms::f64) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_DOUBLE));
      return get_buffer_data(env, data, 8, array_out, schema_out);
    } else if (*atom == atoms::binary) {
      return get_list_string(env, data, NANOARROW_TYPE_BINARY, array_out,
                             schema_out);
    } else if (*atom == atoms::large_binary) {
      return get_list_string(env, data, NANOARROW_TYPE_LARGE_BINARY, array_out,
                             schema_out);
    } else if (*atom == atoms::string) {
      return get_list_string(env, data, NANOARROW_TYPE_STRING, array_out,
                             schema_out);
    } else if (*atom == atoms::large_string) {
      return get_list_string(env, data, NANOARROW_TYPE_LARGE_STRING, array_out,
                             schema_out);
    } else if (*atom == atoms::date32) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_DATE32));
      return get_buffer_data(env, data, 4, array_out, schema_out);
    } else if (*atom == atoms::date64) {
      NANOARROW_THROW_NOT_OK(
          ArrowSchemaSetType(schema_out, NANOARROW_TYPE_DATE64));
      return get_buffer_data(env, data, 8, array_out, schema_out);
    }
  } else if (auto *tuple =
                 std::get_if<std::tuple<fine::Atom, fine::Term>>(&decoded)) {
    auto &[tag, arg] = *tuple;
    if (tag == atoms::time32) {
      if (auto time_unit =
              atom_to_time_unit(fine::decode<fine::Atom>(env, arg))) {
        NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeDateTime(
            schema_out, NANOARROW_TYPE_TIME32, time_unit.value(), NULL));
        return get_buffer_data(env, data, 4, array_out, schema_out);
      }
    } else if (tag == atoms::time64) {
      if (auto time_unit =
              atom_to_time_unit(fine::decode<fine::Atom>(env, arg))) {
        NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeDateTime(
            schema_out, NANOARROW_TYPE_TIME64, time_unit.value(), NULL));
        return get_buffer_data(env, data, 8, array_out, schema_out);
      }
    } else if (tag == atoms::duration) {
      if (auto time_unit =
              atom_to_time_unit(fine::decode<fine::Atom>(env, arg))) {
        NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeDateTime(
            schema_out, NANOARROW_TYPE_DURATION, time_unit.value(), NULL));
        return get_buffer_data(env, data, 8, array_out, schema_out);
      }
    } else if (tag == atoms::interval) {
      auto unit = fine::decode<fine::Atom>(env, arg);
      if (unit == atoms::month) {
        NANOARROW_THROW_NOT_OK(
            ArrowSchemaSetType(schema_out, NANOARROW_TYPE_INTERVAL_MONTHS));
        return get_buffer_data(env, data, 4, array_out, schema_out);
      } else if (unit == atoms::day_time) {
        NANOARROW_THROW_NOT_OK(
            ArrowSchemaSetType(schema_out, NANOARROW_TYPE_INTERVAL_DAY_TIME));
        return get_buffer_data(env, data, 8, array_out, schema_out);
      } else if (unit == atoms::month_day_nano) {
        NANOARROW_THROW_NOT_OK(ArrowSchemaSetType(
            schema_out, NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO));
        return get_buffer_data(env, data, 16, array_out, schema_out);
      }
    } else if (tag == atoms::list) {
      return get_list(env, field.type, data, NANOARROW_TYPE_LIST, 0, array_out,
                      schema_out);
    } else if (tag == atoms::large_list) {
      return get_list(env, field.type, data, NANOARROW_TYPE_LARGE_LIST, 0,
                      array_out, schema_out);
    } else if (tag == atoms::struct_) {
      return get_struct(env, field.type, data, array_out, schema_out);
    } else if (tag == atoms::fixed_size_binary) {
      int32_t fixed_size = fine::decode<int64_t>(env, arg);
      NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeFixedSize(
          schema_out, NANOARROW_TYPE_FIXED_SIZE_BINARY, fixed_size));
      return get_buffer_data(env, data, fixed_size, array_out, schema_out);
    }
  } else if (auto *tuple =
                 std::get_if<std::tuple<fine::Atom, fine::Term, fine::Term>>(
                     &decoded)) {
    auto &[tag, arg1, arg2] = *tuple;
    if (tag == atoms::fixed_size_list) {
      int32_t fixed_size = fine::decode<int64_t>(env, arg2);
      return get_list(env, field.type, data, NANOARROW_TYPE_FIXED_SIZE_LIST,
                      fixed_size, array_out, schema_out);
    } else if (tag == atoms::dictionary) {
      return get_dictionary(env, field.type, data, array_out, schema_out);
    } else if (tag == atoms::timestamp) {
      auto timezone = fine::decode<std::optional<std::string>>(env, arg2);
      if (auto time_unit =
              atom_to_time_unit(fine::decode<fine::Atom>(env, arg1))) {
        const char *tz =
            (timezone && !timezone->empty()) ? timezone->c_str() : nullptr;
        NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeDateTime(
            schema_out, NANOARROW_TYPE_TIMESTAMP, time_unit.value(), tz));
        return get_buffer_data(env, data, 8, array_out, schema_out);
      }
    } else if (tag == atoms::decimal128) {
      int precision = fine::decode<int64_t>(env, arg1);
      int scale = fine::decode<int64_t>(env, arg2);
      NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeDecimal(
          schema_out, NANOARROW_TYPE_DECIMAL128, precision, scale));
      return get_buffer_data(env, data, 16, array_out, schema_out);
    } else if (tag == atoms::decimal256) {
      int precision = fine::decode<int64_t>(env, arg1);
      int scale = fine::decode<int64_t>(env, arg2);
      NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeDecimal(
          schema_out, NANOARROW_TYPE_DECIMAL256, precision, scale));
      return get_buffer_data(env, data, 32, array_out, schema_out);
    }
  }

  throw std::invalid_argument("unsupported type in column_to_arrow");
}

static void columns_to_arrow_record_batch(
    ErlNifEnv *env, const std::vector<ExAdbcColumn> &columns,
    struct ArrowArray *array_out, struct ArrowSchema *schema_out) {
  ArrowSchemaInit(schema_out);
  // A record batch is always an Arrow struct.
  NANOARROW_THROW_NOT_OK(ArrowSchemaSetTypeStruct(schema_out, columns.size()));
  NANOARROW_THROW_NOT_OK(
      ArrowArrayInitFromType(array_out, NANOARROW_TYPE_STRUCT));
  NANOARROW_THROW_NOT_OK(ArrowArrayAllocateChildren(
      array_out, static_cast<int64_t>(columns.size())));

  for (size_t i = 0; i < columns.size(); ++i) {
    auto column = columns[i];
    auto schema_i = schema_out->children[i];
    auto child_i = array_out->children[i];

    ArrowSchemaInit(schema_i);
    column_to_arrow(env, column.field, column.data, child_i, schema_i);

    if (i == 0) {
      // Copy length from the first child.
      array_out->length = child_i->length;
    }
  }

  struct ArrowError arrow_error{};
  if (ArrowArrayFinishBuilding(array_out, NANOARROW_VALIDATION_LEVEL_FULL,
                               &arrow_error) != 0) {
    throw nanoarrow::Exception(arrow_error.message);
  }
}

} // namespace adbc_nif
