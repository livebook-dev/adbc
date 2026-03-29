#ifndef ADBC_ARROW_METADATA_HPP
#define ADBC_ARROW_METADATA_HPP
#pragma once

#include <arrow-adbc/adbc.h>
#include <erl_nif.h>
#include <nanoarrow/nanoarrow.h>
#include <stdio.h>
#include <vector>

#include "adbc_consts.h"
#include "nif_utils.hpp"

static int arrow_metadata_to_nif_term(ErlNifEnv *env, const char *metadata,
                                      ERL_NIF_TERM *out_metadata) {
  std::vector<ERL_NIF_TERM> metadata_keys, metadata_values;
  *out_metadata = kAtomNil;
  if (metadata == nullptr)
    return NANOARROW_OK;

  struct ArrowMetadataReader metadata_reader{};
  struct ArrowStringView key;
  struct ArrowStringView value;
  NANOARROW_RETURN_NOT_OK(ArrowMetadataReaderInit(&metadata_reader, metadata));
  while (ArrowMetadataReaderRead(&metadata_reader, &key, &value) ==
         NANOARROW_OK) {
    // printf("key: %.*s, value: %.*s\n", (int)key.size_bytes, key.data,
    // (int)value.size_bytes, value.data);
    metadata_keys.push_back(
        erlang::nif::make_binary(env, key.data, (size_t)key.size_bytes));
    metadata_values.push_back(
        erlang::nif::make_binary(env, value.data, (size_t)value.size_bytes));
  }
  if (metadata_keys.size() > 0) {
    enif_make_map_from_arrays(env, metadata_keys.data(), metadata_values.data(),
                              (unsigned)metadata_keys.size(), out_metadata);
  }
  return NANOARROW_OK;
}

#endif // ADBC_ARROW_METADATA_HPP
