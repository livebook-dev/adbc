#ifndef ERLANG_NIF_UTILS_HPP
#define ERLANG_NIF_UTILS_HPP

#pragma once

#include <fine.hpp>

static ERL_NIF_TERM encode_error(ErlNifEnv *env, std::string_view error) {
  return fine::encode(env, error);
}

#endif // ERLANG_NIF_UTILS_HPP
