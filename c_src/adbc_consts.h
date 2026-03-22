#ifndef ADBC_CONSTS_H
#pragma once

#include <erl_nif.h>
#include <map>
#include <string>

static std::map<std::string, std::vector<ERL_NIF_TERM>> primitiveFormatMapping;

// Atoms
static ERL_NIF_TERM kAtomAdbcError;
static ERL_NIF_TERM kAtomNil;
static ERL_NIF_TERM kAtomTrue;
static ERL_NIF_TERM kAtomFalse;
static ERL_NIF_TERM kAtomKey;
static ERL_NIF_TERM kAtomValue;
static ERL_NIF_TERM kAtomInfinity;
static ERL_NIF_TERM kAtomNegInfinity;
static ERL_NIF_TERM kAtomNaN;
static ERL_NIF_TERM kAtomEndOfSeries;
static ERL_NIF_TERM kAtomStructKey;
static ERL_NIF_TERM kAtomBig;
static ERL_NIF_TERM kAtomLittle;
static ERL_NIF_TERM kAtomValidity;
static ERL_NIF_TERM kAtomOffsets;
static ERL_NIF_TERM kAtomSizes;
static ERL_NIF_TERM kAtomValues;
static ERL_NIF_TERM kAtomRunEnds;

static ERL_NIF_TERM kAtomDecimal128;
static ERL_NIF_TERM kAtomDecimal256;
static ERL_NIF_TERM kAtomFixedSizeBinary;
static ERL_NIF_TERM kAtomFixedSizeList;
static ERL_NIF_TERM kAtomTime32;
static ERL_NIF_TERM kAtomTime64;
static ERL_NIF_TERM kAtomTimestamp;
static ERL_NIF_TERM kAtomDuration;
static ERL_NIF_TERM kAtomInterval;
static ERL_NIF_TERM kAtomSeconds;
static ERL_NIF_TERM kAtomMilliseconds;
static ERL_NIF_TERM kAtomMicroseconds;
static ERL_NIF_TERM kAtomNanoseconds;
static ERL_NIF_TERM kAtomMonth;
static ERL_NIF_TERM kAtomDayTime;
static ERL_NIF_TERM kAtomMonthDayNano;


static ERL_NIF_TERM kAtomAdbcColumnModule;
static ERL_NIF_TERM kAtomAdbcFieldModule;
static ERL_NIF_TERM kAtomFieldKey;
static ERL_NIF_TERM kAtomNameKey;
static ERL_NIF_TERM kAtomTypeKey;
static ERL_NIF_TERM kAtomNullableKey;
static ERL_NIF_TERM kAtomMetadataKey;
static ERL_NIF_TERM kAtomDataKey;
static ERL_NIF_TERM kAtomLengthKey;
static ERL_NIF_TERM kAtomOffsetKey;

// https://arrow.apache.org/docs/format/CDataInterface.html
static ERL_NIF_TERM kAdbcColumnTypeBool;
static ERL_NIF_TERM kAdbcColumnTypeS8;
static ERL_NIF_TERM kAdbcColumnTypeU8;
static ERL_NIF_TERM kAdbcColumnTypeS16;
static ERL_NIF_TERM kAdbcColumnTypeU16;
static ERL_NIF_TERM kAdbcColumnTypeS32;
static ERL_NIF_TERM kAdbcColumnTypeU32;
static ERL_NIF_TERM kAdbcColumnTypeS64;
static ERL_NIF_TERM kAdbcColumnTypeU64;
static ERL_NIF_TERM kAdbcColumnTypeF16;
static ERL_NIF_TERM kAdbcColumnTypeF32;
static ERL_NIF_TERM kAdbcColumnTypeF64;
static ERL_NIF_TERM kAdbcColumnTypeBinary;
static ERL_NIF_TERM kAdbcColumnTypeLargeBinary;
static ERL_NIF_TERM kAdbcColumnTypeBinaryView;
static ERL_NIF_TERM kAdbcColumnTypeString;
static ERL_NIF_TERM kAdbcColumnTypeLargeString;
static ERL_NIF_TERM kAdbcColumnTypeStringView;
#define kAdbcColumnTypeDecimal128(precision, scale) enif_make_tuple3(env, kAtomDecimal128, enif_make_int(env, precision), enif_make_int(env, scale))
#define kAdbcColumnTypeDecimal256(precision, scale) enif_make_tuple3(env, kAtomDecimal256, enif_make_int(env, precision), enif_make_int(env, scale))
#define kAdbcColumnTypeFixedSizeBinary(nbytes) enif_make_tuple2(env, kAtomFixedSizeBinary, enif_make_int64(env, nbytes))
static ERL_NIF_TERM kAdbcColumnTypeDate32;
static ERL_NIF_TERM kAdbcColumnTypeDate64;
#define kAdbcColumnTypeTime32Seconds enif_make_tuple2(env, kAtomTime32, kAtomSeconds)
#define kAdbcColumnTypeTime32Milliseconds enif_make_tuple2(env, kAtomTime32, kAtomMilliseconds)
#define kAdbcColumnTypeTime64Microseconds enif_make_tuple2(env, kAtomTime64, kAtomMicroseconds)
#define kAdbcColumnTypeTime64Nanoseconds enif_make_tuple2(env, kAtomTime64, kAtomNanoseconds)
#define kAdbcColumnTypeDurationSeconds enif_make_tuple2(env, kAtomDuration, kAtomSeconds)
#define kAdbcColumnTypeDurationMilliseconds enif_make_tuple2(env, kAtomDuration, kAtomMilliseconds)
#define kAdbcColumnTypeDurationMicroseconds enif_make_tuple2(env, kAtomDuration, kAtomMicroseconds)
#define kAdbcColumnTypeDurationNanoseconds enif_make_tuple2(env, kAtomDuration, kAtomNanoseconds)
#define kAdbcColumnTypeIntervalMonth enif_make_tuple2(env, kAtomInterval, kAtomMonth)
#define kAdbcColumnTypeIntervalDayTime enif_make_tuple2(env, kAtomInterval, kAtomDayTime)
#define kAdbcColumnTypeIntervalMonthDayNano enif_make_tuple2(env, kAtomInterval, kAtomMonthDayNano)
static ERL_NIF_TERM kAdbcColumnTypeList;
static ERL_NIF_TERM kAdbcColumnTypeLargeList;
static ERL_NIF_TERM kAdbcColumnTypeListView;
static ERL_NIF_TERM kAdbcColumnTypeLargeListView;
#define kAdbcColumnTypeFixedSizeList(n_items) enif_make_tuple2(env, kAtomFixedSizeBinary, enif_make_int64(env, n_items))
static ERL_NIF_TERM kAdbcColumnTypeStruct;
static ERL_NIF_TERM kAdbcColumnTypeMap;
static ERL_NIF_TERM kAdbcColumnTypeDenseUnion;
static ERL_NIF_TERM kAdbcColumnTypeSparseUnion;
static ERL_NIF_TERM kAdbcColumnTypeRunEndEncoded;
static ERL_NIF_TERM kAdbcColumnTypeDictionary;

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
constexpr int kErrorNilInNonNullableColumn = 12;

#endif  // ADBC_CONSTS_H
