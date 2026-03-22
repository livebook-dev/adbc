defmodule Adbc.Helper do
  @moduledoc false

  def error_to_exception(string) when is_binary(string) do
    ArgumentError.exception(string)
  end

  def error_to_exception(list) when is_list(list) do
    ArgumentError.exception(List.to_string(list))
  end

  def error_to_exception({:adbc_error, message, vendor_code, state}) do
    Adbc.Error.exception(message: message, vendor_code: vendor_code, state: state)
  end

  def error_to_exception(%Adbc.Error{} = exception) do
    exception
  end

  def option(callee, func, args)

  def option(pid, func, args) when is_pid(pid) do
    case GenServer.call(pid, {:option, func, args}) do
      :ok ->
        :ok

      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, error_to_exception(reason)}
    end
  end

  def option(ref, func, [type, key | args]) when is_reference(ref) do
    with {:error, reason} <- apply(Adbc.Nif, func, [ref, type, to_string(key) | args]) do
      {:error, error_to_exception(reason)}
    end
  end

  def option_ok_or_halt(callee, func, args) do
    case option(callee, func, args) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  # Use to avoid premature GC of capsules
  def noop(value), do: value

  if Code.ensure_loaded?(Pythonx) do
    def from_py(py_object) when is_struct(py_object, Pythonx.Object) do
      {_, globals} =
        Pythonx.eval(
          """
          if hasattr(object, "__arrow_c_stream__"):
            import ctypes

            has_stream = True
            capsule = object.__arrow_c_stream__()
            ctypes.pythonapi.PyCapsule_GetPointer.restype = ctypes.c_void_p
            ctypes.pythonapi.PyCapsule_GetPointer.argtypes = [ctypes.py_object, ctypes.c_char_p]
            pointer = ctypes.pythonapi.PyCapsule_GetPointer(capsule, b"arrow_array_stream")

          else:
            has_stream = False
            capsule = None
            pointer = None
          """,
          %{"object" => py_object}
        )

      if Pythonx.decode(globals["has_stream"]) do
        capsule = globals["capsule"]
        pointer = Pythonx.decode(globals["pointer"])

        case Adbc.Nif.adbc_arrow_array_stream_from_pointer(pointer) do
          {:ok, stream_ref} -> {:ok, stream_ref, capsule}
          {:error, reason} -> {:error, error_to_exception(reason)}
        end
      else
        {:error,
         ArgumentError.exception("""
         the given Python object does not support ArrowStream Export interface (__arrow_c_stream__ method is missing)\
         """)}
      end
    end
  else
    def from_py(_py_object) do
      {:error,
       RuntimeError.exception("""
       Adbc.Helper.from_py/1 requires pythonx to be available, add it to your mix.exs:

           {:pythonx, "~> 0.4.0"}
       """)}
    end
  end

  @doc false
  def download(url, ignore_proxy) do
    url_charlist = String.to_charlist(url)

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:public_key)

    if !ignore_proxy do
      if proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy") do
        %{host: host, port: port} = URI.parse(proxy)
        :httpc.set_options([{:proxy, {{String.to_charlist(host), port}, []}}])
      end

      if proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
        %{host: host, port: port} = URI.parse(proxy)
        :httpc.set_options([{:https_proxy, {{String.to_charlist(host), port}, []}}])
      end
    end

    # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
    # TODO: This may no longer be necessary from Erlang/OTP 25.0 or later.
    https_options = [
      ssl:
        [
          verify: :verify_peer,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts_options()
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, {url_charlist, []}, https_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      other ->
        {:error, "couldn't fetch file from #{url}: #{inspect(other)}"}
    end
  end

  defp cacerts_options do
    cond do
      custom_certs = System.get_env("ADBC_CACERTS_PATH") ->
        [cacertfile: custom_certs]

      certs = otp_cacerts() ->
        [cacerts: certs]

      true ->
        IO.warn("""
        No certificate trust store was found.

        A certificate trust store is required in
        order to download locales for your configuration.
        Since elixir_make could not detect a system
        installed certificate trust store one of the
        following actions may be taken:

        1. Use OTP 25+ on an OS that has built-in certificate trust store.

        2. Set ADBC_CACERTS_PATH environment variable pointing to a certificate.

        """)

        []
    end
  end

  defp otp_cacerts do
    :public_key.cacerts_get()
  rescue
    _ -> nil
  end
end
