-module(version_bump_ffi).
-export([halt/1]).

%% Halt the BEAM with the given exit status code. Used by the CLI to exit
%% non-zero on a failed release. Returns no value (the VM stops).
halt(Code) ->
    erlang:halt(Code).
