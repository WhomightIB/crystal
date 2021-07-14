require "./repl"

# Information about a C function that needs to be called.
class Crystal::Repl::LibFunction
  # The external function
  getter def : External

  # Symbol returned by dlopen and dlsym that is a pointer
  # to the actual function.
  getter symbol : Void*

  # The FFI call interface definition to call the C function
  getter call_interface : FFI::CallInterface

  # Bytesize for each argument in the call
  getter args_bytesizes : Array(Int32)

  # Each element is non-nil if the argument at that index
  # is a Proc/callback, and it has the information of that
  # Proc.
  getter proc_args : Array(FFI::CallInterface?)

  def initialize(
    @def : Def,
    @symbol : Void*,
    @call_interface : FFI::CallInterface,
    @args_bytesizes : Array(Int32),
    @proc_args : Array(FFI::CallInterface?)
  )
  end
end
