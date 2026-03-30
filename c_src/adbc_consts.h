#ifndef ADBC_CONSTS_H
#pragma once

#include <erl_nif.h>
#include <fine.hpp>

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
inline fine::Atom ElixirAdbcColumn("Elixir.Adbc.Column");
inline fine::Atom ElixirAdbcField("Elixir.Adbc.Field");
inline fine::Atom ElixirAdbcDictionaryData("Elixir.Adbc.DictionaryData");
inline fine::Atom ElixirAdbcRunEndEncodedData("Elixir.Adbc.RunEndEncodedData");
inline fine::Atom ElixirAdbcListViewData("Elixir.Adbc.ListViewData");
inline fine::Atom ElixirAdbcListData("Elixir.Adbc.ListData");
inline fine::Atom ElixirAdbcBufferData("Elixir.Adbc.BufferData");
inline fine::Atom ElixirAdbcBinaryData("Elixir.Adbc.BinaryData");
inline fine::Atom ElixirAdbcStructData("Elixir.Adbc.StructData");
inline fine::Atom ElixirAdbcBooleanData("Elixir.Adbc.BooleanData");

// Field key atoms
inline fine::Atom field("field");
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

// Tuple type constructors (require `env` in scope)
#define kAdbcColumnTypeDecimal128(precision, scale) enif_make_tuple3(env, fine::encode(env, atoms::decimal128), enif_make_int(env, precision), enif_make_int(env, scale))
#define kAdbcColumnTypeDecimal256(precision, scale) enif_make_tuple3(env, fine::encode(env, atoms::decimal256), enif_make_int(env, precision), enif_make_int(env, scale))
#define kAdbcColumnTypeFixedSizeBinary(nbytes) enif_make_tuple2(env, fine::encode(env, atoms::fixed_size_binary), enif_make_int64(env, nbytes))
#define kAdbcColumnTypeTime32Seconds enif_make_tuple2(env, fine::encode(env, atoms::time32), fine::encode(env, atoms::seconds))
#define kAdbcColumnTypeTime32Milliseconds enif_make_tuple2(env, fine::encode(env, atoms::time32), fine::encode(env, atoms::milliseconds))
#define kAdbcColumnTypeTime64Microseconds enif_make_tuple2(env, fine::encode(env, atoms::time64), fine::encode(env, atoms::microseconds))
#define kAdbcColumnTypeTime64Nanoseconds enif_make_tuple2(env, fine::encode(env, atoms::time64), fine::encode(env, atoms::nanoseconds))
#define kAdbcColumnTypeDurationSeconds enif_make_tuple2(env, fine::encode(env, atoms::duration), fine::encode(env, atoms::seconds))
#define kAdbcColumnTypeDurationMilliseconds enif_make_tuple2(env, fine::encode(env, atoms::duration), fine::encode(env, atoms::milliseconds))
#define kAdbcColumnTypeDurationMicroseconds enif_make_tuple2(env, fine::encode(env, atoms::duration), fine::encode(env, atoms::microseconds))
#define kAdbcColumnTypeDurationNanoseconds enif_make_tuple2(env, fine::encode(env, atoms::duration), fine::encode(env, atoms::nanoseconds))
#define kAdbcColumnTypeIntervalMonth enif_make_tuple2(env, fine::encode(env, atoms::interval), fine::encode(env, atoms::month))
#define kAdbcColumnTypeIntervalDayTime enif_make_tuple2(env, fine::encode(env, atoms::interval), fine::encode(env, atoms::day_time))
#define kAdbcColumnTypeIntervalMonthDayNano enif_make_tuple2(env, fine::encode(env, atoms::interval), fine::encode(env, atoms::month_day_nano))
#define kAdbcColumnTypeFixedSizeList(inner_field, n_items) enif_make_tuple3(env, fine::encode(env, atoms::fixed_size_list), inner_field, enif_make_int64(env, n_items))

// error codes
constexpr int kErrorBufferIsNotAMap = 1;
constexpr int kErrorBufferGetDataListLength = 2;
constexpr int kErrorBufferGetMapValue = 3;
constexpr int kErrorBufferWrongStruct = 4;
constexpr int kErrorBufferDataIsNotAList = 5;
constexpr int kErrorBufferDataIsNotAMap = 6;
constexpr int kErrorBufferUnknownType = 7;
constexpr int kErrorBufferGetMetadataKey = 8;
constexpr int kErrorBufferGetMetadataValue = 9;
constexpr int kErrorInternalError = 11;

#endif  // ADBC_CONSTS_H
