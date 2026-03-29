#ifndef ADBC_CONSTS_H
#pragma once

#include <erl_nif.h>
#include <fine.hpp>

// Wrapper around fine::Atom that is implicitly convertible to ERL_NIF_TERM.
// After FINE_INIT's load callback, operator ERL_NIF_TERM() is safe to call.
struct FAtom : fine::Atom {
    using fine::Atom::Atom;
    operator ERL_NIF_TERM() const {
        return fine::encode(nullptr, static_cast<const fine::Atom&>(*this));
    }
};

// Atoms
inline FAtom kAtomAdbcError("adbc_error");
inline FAtom kAtomNil("nil");
inline FAtom kAtomTrue("true");
inline FAtom kAtomFalse("false");
inline FAtom kAtomKey("key");
inline FAtom kAtomValue("value");
inline FAtom kAtomInfinity("infinity");
inline FAtom kAtomNegInfinity("neg_infinity");
inline FAtom kAtomNaN("nan");
inline FAtom kAtomEndOfSeries("end_of_series");
inline FAtom kAtomStructKey("__struct__");
inline FAtom kAtomBig("big");
inline FAtom kAtomLittle("little");
inline FAtom kAtomValidity("validity");
inline FAtom kAtomOffsets("offsets");
inline FAtom kAtomSizes("sizes");
inline FAtom kAtomValues("values");
inline FAtom kAtomRunEnds("run_ends");

inline FAtom kAtomDecimal128("decimal128");
inline FAtom kAtomDecimal256("decimal256");
inline FAtom kAtomFixedSizeBinary("fixed_size_binary");
inline FAtom kAtomFixedSizeList("fixed_size_list");
inline FAtom kAtomTime32("time32");
inline FAtom kAtomTime64("time64");
inline FAtom kAtomTimestamp("timestamp");
inline FAtom kAtomDuration("duration");
inline FAtom kAtomInterval("interval");
inline FAtom kAtomSeconds("seconds");
inline FAtom kAtomMilliseconds("milliseconds");
inline FAtom kAtomMicroseconds("microseconds");
inline FAtom kAtomNanoseconds("nanoseconds");
inline FAtom kAtomMonth("month");
inline FAtom kAtomDayTime("day_time");
inline FAtom kAtomMonthDayNano("month_day_nano");


inline FAtom kAtomAdbcColumnModule("Elixir.Adbc.Column");
inline FAtom kAtomAdbcFieldModule("Elixir.Adbc.Field");
inline FAtom kAtomAdbcDictionaryDataModule("Elixir.Adbc.DictionaryData");
inline FAtom kAtomAdbcRunEndEncodedDataModule("Elixir.Adbc.RunEndEncodedData");
inline FAtom kAtomAdbcListViewDataModule("Elixir.Adbc.ListViewData");
inline FAtom kAtomAdbcListDataModule("Elixir.Adbc.ListData");
inline FAtom kAtomAdbcBufferDataModule("Elixir.Adbc.BufferData");
inline FAtom kAtomAdbcBinaryDataModule("Elixir.Adbc.BinaryData");
inline FAtom kAtomAdbcStructDataModule("Elixir.Adbc.StructData");
inline FAtom kAtomAdbcBooleanDataModule("Elixir.Adbc.BooleanData");
inline FAtom kAtomFieldKey("field");
inline FAtom kAtomNameKey("name");
inline FAtom kAtomTypeKey("type");
inline FAtom kAtomMetadataKey("metadata");
inline FAtom kAtomDataKey("data");
inline FAtom kAtomSizeKey("size");
inline FAtom kAtomLengthKey("length");
inline FAtom kAtomOffsetKey("offset");
inline FAtom kAtomBitOffsetKey("bit_offset");

// https://arrow.apache.org/docs/format/CDataInterface.html
inline FAtom kAdbcColumnTypeBool("boolean");
inline FAtom kAdbcColumnTypeS8("s8");
inline FAtom kAdbcColumnTypeU8("u8");
inline FAtom kAdbcColumnTypeS16("s16");
inline FAtom kAdbcColumnTypeU16("u16");
inline FAtom kAdbcColumnTypeS32("s32");
inline FAtom kAdbcColumnTypeU32("u32");
inline FAtom kAdbcColumnTypeS64("s64");
inline FAtom kAdbcColumnTypeU64("u64");
inline FAtom kAdbcColumnTypeF16("f16");
inline FAtom kAdbcColumnTypeF32("f32");
inline FAtom kAdbcColumnTypeF64("f64");
inline FAtom kAdbcColumnTypeBinary("binary");
inline FAtom kAdbcColumnTypeLargeBinary("large_binary");
inline FAtom kAdbcColumnTypeBinaryView("binary_view");
inline FAtom kAdbcColumnTypeString("string");
inline FAtom kAdbcColumnTypeLargeString("large_string");
inline FAtom kAdbcColumnTypeStringView("string_view");
#define kAdbcColumnTypeDecimal128(precision, scale) enif_make_tuple3(env, static_cast<ERL_NIF_TERM>(kAtomDecimal128), enif_make_int(env, precision), enif_make_int(env, scale))
#define kAdbcColumnTypeDecimal256(precision, scale) enif_make_tuple3(env, static_cast<ERL_NIF_TERM>(kAtomDecimal256), enif_make_int(env, precision), enif_make_int(env, scale))
#define kAdbcColumnTypeFixedSizeBinary(nbytes) enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomFixedSizeBinary), enif_make_int64(env, nbytes))
inline FAtom kAdbcColumnTypeDate32("date32");
inline FAtom kAdbcColumnTypeDate64("date64");
#define kAdbcColumnTypeTime32Seconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomTime32), static_cast<ERL_NIF_TERM>(kAtomSeconds))
#define kAdbcColumnTypeTime32Milliseconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomTime32), static_cast<ERL_NIF_TERM>(kAtomMilliseconds))
#define kAdbcColumnTypeTime64Microseconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomTime64), static_cast<ERL_NIF_TERM>(kAtomMicroseconds))
#define kAdbcColumnTypeTime64Nanoseconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomTime64), static_cast<ERL_NIF_TERM>(kAtomNanoseconds))
#define kAdbcColumnTypeDurationSeconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomDuration), static_cast<ERL_NIF_TERM>(kAtomSeconds))
#define kAdbcColumnTypeDurationMilliseconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomDuration), static_cast<ERL_NIF_TERM>(kAtomMilliseconds))
#define kAdbcColumnTypeDurationMicroseconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomDuration), static_cast<ERL_NIF_TERM>(kAtomMicroseconds))
#define kAdbcColumnTypeDurationNanoseconds enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomDuration), static_cast<ERL_NIF_TERM>(kAtomNanoseconds))
#define kAdbcColumnTypeIntervalMonth enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomInterval), static_cast<ERL_NIF_TERM>(kAtomMonth))
#define kAdbcColumnTypeIntervalDayTime enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomInterval), static_cast<ERL_NIF_TERM>(kAtomDayTime))
#define kAdbcColumnTypeIntervalMonthDayNano enif_make_tuple2(env, static_cast<ERL_NIF_TERM>(kAtomInterval), static_cast<ERL_NIF_TERM>(kAtomMonthDayNano))
inline FAtom kAdbcColumnTypeList("list");
inline FAtom kAdbcColumnTypeLargeList("large_list");
inline FAtom kAdbcColumnTypeListView("list_view");
inline FAtom kAdbcColumnTypeLargeListView("large_list_view");
#define kAdbcColumnTypeFixedSizeList(inner_field, n_items) enif_make_tuple3(env, static_cast<ERL_NIF_TERM>(kAtomFixedSizeList), inner_field, enif_make_int64(env, n_items))
inline FAtom kAdbcColumnTypeStruct("struct");
inline FAtom kAdbcColumnTypeMap("map");
inline FAtom kAdbcColumnTypeDenseUnion("dense_union");
inline FAtom kAdbcColumnTypeSparseUnion("sparse_union");
inline FAtom kAdbcColumnTypeRunEndEncoded("run_end_encoded");
inline FAtom kAdbcColumnTypeDictionary("dictionary");

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
