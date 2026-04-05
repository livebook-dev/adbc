#pragma once

#include <arrow-adbc/adbc.h>
#include <erl_nif.h>
#include <fine.hpp>
#include <nanoarrow/nanoarrow.hpp>
#include <optional>

namespace adbc_nif {

namespace atoms {

// Basic
inline fine::Atom adbc_error("adbc_error");
inline fine::Atom nil("nil");
inline fine::Atom true_("true");
inline fine::Atom false_("false");
inline fine::Atom key("key");
inline fine::Atom value("value");
inline fine::Atom infinity("infinity");
inline fine::Atom neg_infinity("neg_infinity");
inline fine::Atom nan("nan");
inline fine::Atom end_of_series("end_of_series");
inline fine::Atom execute_on_gc("execute_on_gc");
inline fine::Atom struct_key("__struct__");
inline fine::Atom big("big");
inline fine::Atom little("little");
inline fine::Atom validity("validity");
inline fine::Atom offsets("offsets");
inline fine::Atom sizes("sizes");
inline fine::Atom values("values");
inline fine::Atom keys("keys");
inline fine::Atom run_ends("run_ends");

// Type modifier atoms
inline fine::Atom decimal128("decimal128");
inline fine::Atom decimal256("decimal256");
inline fine::Atom fixed_size_binary("fixed_size_binary");
inline fine::Atom fixed_size_list("fixed_size_list");
inline fine::Atom time32("time32");
inline fine::Atom time64("time64");
inline fine::Atom timestamp("timestamp");
inline fine::Atom duration("duration");
inline fine::Atom interval("interval");
inline fine::Atom seconds("seconds");
inline fine::Atom milliseconds("milliseconds");
inline fine::Atom microseconds("microseconds");
inline fine::Atom nanoseconds("nanoseconds");
inline fine::Atom month("month");
inline fine::Atom day_time("day_time");
inline fine::Atom month_day_nano("month_day_nano");

// Module atoms
inline fine::Atom ElixirArgumentError("Elixir.ArgumentError");
inline fine::Atom ElixirAdbcError("Elixir.Adbc.Error");
inline fine::Atom ElixirAdbcColumn("Elixir.Adbc.Column");
inline fine::Atom ElixirAdbcField("Elixir.Adbc.Field");
inline fine::Atom ElixirAdbcDictionaryData("Elixir.Adbc.DictionaryData");
inline fine::Atom ElixirAdbcRunEndEncodedData("Elixir.Adbc.RunEndEncodedData");
inline fine::Atom ElixirAdbcListViewData("Elixir.Adbc.ListViewData");
inline fine::Atom ElixirAdbcListData("Elixir.Adbc.ListData");
inline fine::Atom ElixirAdbcMapData("Elixir.Adbc.MapData");
inline fine::Atom ElixirAdbcBufferData("Elixir.Adbc.BufferData");
inline fine::Atom ElixirAdbcBinaryData("Elixir.Adbc.BinaryData");
inline fine::Atom ElixirAdbcStructData("Elixir.Adbc.StructData");
inline fine::Atom ElixirAdbcBooleanData("Elixir.Adbc.BooleanData");

// Field key atoms
inline fine::Atom field("field");
inline fine::Atom message("message");
inline fine::Atom vendor_code("vendor_code");
inline fine::Atom state("state");
inline fine::Atom name("name");
inline fine::Atom type("type");
inline fine::Atom metadata("metadata");
inline fine::Atom data("data");
inline fine::Atom size("size");
inline fine::Atom length("length");
inline fine::Atom offset("offset");
inline fine::Atom bit_offset("bit_offset");

// Column type atoms
inline fine::Atom boolean("boolean");
inline fine::Atom s8("s8");
inline fine::Atom u8("u8");
inline fine::Atom s16("s16");
inline fine::Atom u16("u16");
inline fine::Atom s32("s32");
inline fine::Atom u32("u32");
inline fine::Atom s64("s64");
inline fine::Atom u64("u64");
inline fine::Atom f16("f16");
inline fine::Atom f32("f32");
inline fine::Atom f64("f64");
inline fine::Atom binary("binary");
inline fine::Atom large_binary("large_binary");
inline fine::Atom binary_view("binary_view");
inline fine::Atom string("string");
inline fine::Atom large_string("large_string");
inline fine::Atom string_view("string_view");
inline fine::Atom date32("date32");
inline fine::Atom date64("date64");
inline fine::Atom list("list");
inline fine::Atom large_list("large_list");
inline fine::Atom list_view("list_view");
inline fine::Atom large_list_view("large_list_view");
inline fine::Atom struct_("struct");
inline fine::Atom map("map");
inline fine::Atom dense_union("dense_union");
inline fine::Atom sparse_union("sparse_union");
inline fine::Atom run_end_encoded("run_end_encoded");
inline fine::Atom dictionary("dictionary");

} // namespace atoms

static ERL_NIF_TERM encode_error(ErlNifEnv *env, std::string_view error) {
  return fine::encode(env, error);
}

struct ExArgumentError {
  std::string message;

  ExArgumentError() {}
  ExArgumentError(std::string message) : message(std::move(message)) {}

  static constexpr auto module = &atoms::ElixirArgumentError;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExArgumentError::message, &atoms::message));
  }

  static constexpr auto is_exception = true;
};

struct ExAdbcError {
  std::string message;
  std::optional<int64_t> vendor_code;
  std::optional<std::string> state;

  ExAdbcError() {}

  ExAdbcError(struct AdbcError *adbc_error) {
    message = (adbc_error->message == nullptr) ? "unknown error"
                                               : adbc_error->message;
    vendor_code = adbc_error->vendor_code;
    state = std::string(adbc_error->sqlstate, sizeof(adbc_error->sqlstate));
    if (adbc_error->release != nullptr) {
      adbc_error->release(adbc_error);
    }
  }

  static constexpr auto module = &atoms::ElixirAdbcError;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcError::message, &atoms::message),
        std::make_tuple(&ExAdbcError::vendor_code, &atoms::vendor_code),
        std::make_tuple(&ExAdbcError::state, &atoms::state));
  }

  static constexpr auto is_exception = true;
};

struct ExAdbcField {
  std::optional<std::string> name;
  fine::Term type;
  fine::Term metadata;

  static constexpr auto module = &atoms::ElixirAdbcField;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcField::name, &atoms::name),
        std::make_tuple(&ExAdbcField::type, &atoms::type),
        std::make_tuple(&ExAdbcField::metadata, &atoms::metadata));
  }
};

struct ExAdbcColumn {
  ExAdbcField field;
  fine::Term data;
  std::optional<uint64_t> size;

  static constexpr auto module = &atoms::ElixirAdbcColumn;

  static constexpr auto fields() {
    return std::make_tuple(std::make_tuple(&ExAdbcColumn::field, &atoms::field),
                           std::make_tuple(&ExAdbcColumn::data, &atoms::data),
                           std::make_tuple(&ExAdbcColumn::size, &atoms::size));
  }
};

struct ExAdbcBufferData {
  fine::Term data;
  std::optional<fine::Term> validity;
  uint64_t bit_offset;

  static constexpr auto module = &atoms::ElixirAdbcBufferData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcBufferData::data, &atoms::data),
        std::make_tuple(&ExAdbcBufferData::validity, &atoms::validity),
        std::make_tuple(&ExAdbcBufferData::bit_offset, &atoms::bit_offset));
  }
};

struct ExAdbcBooleanData {
  fine::Term data;
  std::optional<fine::Term> validity;
  uint64_t bit_offset;
  uint64_t size;

  static constexpr auto module = &atoms::ElixirAdbcBooleanData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcBooleanData::data, &atoms::data),
        std::make_tuple(&ExAdbcBooleanData::validity, &atoms::validity),
        std::make_tuple(&ExAdbcBooleanData::bit_offset, &atoms::bit_offset),
        std::make_tuple(&ExAdbcBooleanData::size, &atoms::size));
  }
};

struct ExAdbcBinaryData {
  fine::Term offsets;
  fine::Term data;
  std::optional<fine::Term> validity;
  uint64_t bit_offset;

  static constexpr auto module = &atoms::ElixirAdbcBinaryData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcBinaryData::offsets, &atoms::offsets),
        std::make_tuple(&ExAdbcBinaryData::data, &atoms::data),
        std::make_tuple(&ExAdbcBinaryData::validity, &atoms::validity),
        std::make_tuple(&ExAdbcBinaryData::bit_offset, &atoms::bit_offset));
  }
};

struct ExAdbcStructData {
  std::optional<fine::Term> validity;
  uint64_t bit_offset;
  fine::Term values;

  static constexpr auto module = &atoms::ElixirAdbcStructData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcStructData::validity, &atoms::validity),
        std::make_tuple(&ExAdbcStructData::bit_offset, &atoms::bit_offset),
        std::make_tuple(&ExAdbcStructData::values, &atoms::values));
  }
};

struct ExAdbcDictionaryData {
  fine::Term key;
  fine::Term value;

  static constexpr auto module = &atoms::ElixirAdbcDictionaryData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcDictionaryData::key, &atoms::key),
        std::make_tuple(&ExAdbcDictionaryData::value, &atoms::value));
  }
};

struct ExAdbcListData {
  fine::Term offsets;
  std::optional<fine::Term> validity;
  fine::Term values;
  uint64_t bit_offset;

  static constexpr auto module = &atoms::ElixirAdbcListData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcListData::offsets, &atoms::offsets),
        std::make_tuple(&ExAdbcListData::validity, &atoms::validity),
        std::make_tuple(&ExAdbcListData::values, &atoms::values),
        std::make_tuple(&ExAdbcListData::bit_offset, &atoms::bit_offset));
  }
};

struct ExAdbcMapData {
  fine::Term offsets;
  std::optional<fine::Term> validity;
  fine::Term keys;
  fine::Term values;
  uint64_t bit_offset;

  static constexpr auto module = &atoms::ElixirAdbcMapData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcMapData::offsets, &atoms::offsets),
        std::make_tuple(&ExAdbcMapData::validity, &atoms::validity),
        std::make_tuple(&ExAdbcMapData::keys, &atoms::keys),
        std::make_tuple(&ExAdbcMapData::values, &atoms::values),
        std::make_tuple(&ExAdbcMapData::bit_offset, &atoms::bit_offset));
  }
};

struct ExAdbcRunEndEncodedData {
  fine::Term run_ends;
  fine::Term values;
  int64_t length;
  int64_t offset;

  static constexpr auto module = &atoms::ElixirAdbcRunEndEncodedData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcRunEndEncodedData::run_ends, &atoms::run_ends),
        std::make_tuple(&ExAdbcRunEndEncodedData::values, &atoms::values),
        std::make_tuple(&ExAdbcRunEndEncodedData::length, &atoms::length),
        std::make_tuple(&ExAdbcRunEndEncodedData::offset, &atoms::offset));
  }
};

struct ExAdbcListViewData {
  fine::Term offsets;
  fine::Term sizes;
  std::optional<fine::Term> validity;
  fine::Term values;
  uint64_t bit_offset;

  static constexpr auto module = &atoms::ElixirAdbcListViewData;

  static constexpr auto fields() {
    return std::make_tuple(
        std::make_tuple(&ExAdbcListViewData::offsets, &atoms::offsets),
        std::make_tuple(&ExAdbcListViewData::sizes, &atoms::sizes),
        std::make_tuple(&ExAdbcListViewData::validity, &atoms::validity),
        std::make_tuple(&ExAdbcListViewData::values, &atoms::values),
        std::make_tuple(&ExAdbcListViewData::bit_offset, &atoms::bit_offset));
  }
};

struct ArrowArrayStreamRecord {
  nanoarrow::UniqueSchema schema;
  nanoarrow::UniqueArray values;

  void destructor(ErlNifEnv *env) {}
};

} // namespace adbc_nif
