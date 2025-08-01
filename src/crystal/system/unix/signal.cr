require "c/signal"
require "c/stdio"
require "c/sys/wait"
require "c/unistd"

module Crystal::System::Signal
  # The number of libc functions that can be called safely from a signal(2)
  # handler is very limited. An usual safe solution is to use a pipe(2) and
  # just write the signal to the file descriptor and nothing more. A loop in
  # the main program is responsible for reading the signals back from the
  # pipe(2) and handle the signal there.

  alias Handler = ::Signal ->

  @@pipe = IO.pipe(read_blocking: false, write_blocking: true)
  @@handlers = {} of ::Signal => Handler
  @@sigset = Sigset.new
  class_property child_handler : Handler?
  @@mutex = Mutex.new(:unchecked)

  def self.trap(signal, handler) : Nil
    @@mutex.synchronize do
      unless @@handlers[signal]?
        @@sigset << signal
        {% if flag?(:interpreted) && Crystal::Interpreter.class.has_method?(:signal) %}
          Crystal::Interpreter.signal(signal.value, 2)
        {% else %}
          action = LibC::Sigaction.new

          # restart some interrupted syscalls (read, write, accept, ...) instead
          # of returning EINTR:
          action.sa_flags = LibC::SA_RESTART

          action.sa_sigaction = LibC::SigactionHandlerT.new do |value, _, _|
            FileDescriptor.write_fully(writer.fd, pointerof(value)) unless writer.closed?
          end
          LibC.sigemptyset(pointerof(action.@sa_mask))
          LibC.sigaction(signal, pointerof(action), nil)
        {% end %}
      end
      @@handlers[signal] = handler
    end
  end

  def self.trap_handler?(signal)
    @@mutex.synchronize { @@handlers[signal]? }
  end

  def self.reset(signal) : Nil
    set(signal, LibC::SIG_DFL)
  end

  def self.ignore(signal) : Nil
    set(signal, LibC::SIG_IGN)
  end

  private def self.set(signal, handler)
    if signal == ::Signal::CHLD
      # Clear any existing signal child handler
      @@child_handler = nil
      # But keep a default SIGCHLD, Process#wait requires it
      trap(signal, ->(signal : ::Signal) {
        SignalChildHandler.call
        @@child_handler.try(&.call(signal))
      })
    else
      @@mutex.synchronize do
        @@handlers.delete(signal)
        {% if flag?(:interpreted) && Crystal::Interpreter.class.has_method?(:signal) %}
          h = case handler
              when LibC::SIG_DFL then 0
              when LibC::SIG_IGN then 1
              else                    2
              end
          Crystal::Interpreter.signal(signal.value, h)
        {% else %}
          LibC.signal(signal, handler)
        {% end %}
        @@sigset.delete(signal)
      end
    end
  end

  private def self.start_loop
    spawn(name: "signal-loop") do
      loop do
        value = reader.read_bytes(Int32)
      rescue IO::Error
        next
      else
        process(::Signal.new(value))
      end
    end
  end

  private def self.process(signal) : Nil
    if handler = @@handlers[signal]?
      non_nil_handler = handler # if handler is closured it will also have the Nil type
      spawn do
        non_nil_handler.call(signal)
      rescue ex
        ex.inspect_with_backtrace(STDERR)
        fatal("uncaught exception while processing handler for #{signal}")
      end
    else
      fatal("missing handler for #{signal}")
    end
  end

  # Replaces the signal pipe so the child process won't share the file
  # descriptors of the parent process and send it received signals.
  def self.after_fork
    @@pipe.each do |pipe_io|
      Crystal::EventLoop.remove(pipe_io)
      pipe_io.file_descriptor_close { }
    end
  ensure
    @@pipe = IO.pipe(read_blocking: false, write_blocking: true)
  end

  # Resets signal handlers to `SIG_DFL`. This avoids the child to receive
  # signals that would be sent to the parent process through the signal
  # pipe.
  #
  # We keep a signal set to because accessing @@handlers isn't thread safe —a
  # thread could be mutating the hash while another one forked. This allows to
  # only reset a few signals (fast) rather than all (very slow).
  #
  # We eventually close the pipe anyway to avoid a potential race where a sigset
  # wouldn't exactly reflect actual signal state. This avoids sending a children
  # signal to the parent. Exec will reset the signals properly for the
  # sub-process.
  def self.after_fork_before_exec
    ::Signal.each do |signal|
      next unless @@sigset.includes?(signal)

      {% if flag?(:interpreted) && Crystal::Interpreter.class.has_method?(:signal) %}
        Crystal::Interpreter.signal(signal.value, 0)
      {% else %}
        LibC.signal(signal, LibC::SIG_DFL)
      {% end %}
    end
  ensure
    {% unless flag?(:preview_mt) %}
      @@pipe.each(&.file_descriptor_close)
    {% end %}
  end

  private def self.reader
    @@pipe[0]
  end

  private def self.writer
    @@pipe[1]
  end

  {% unless flag?(:interpreted) %}
    # :nodoc:
    def self.writer=(writer : IO::FileDescriptor)
      @@pipe = {@@pipe[0], writer}
      writer
    end
  {% end %}

  private def self.fatal(message : String)
    STDERR.puts("FATAL: #{message}, exiting")
    STDERR.flush
    LibC._exit(1)
  end

  @@setup_default_handlers = Atomic(Bool).new(false)
  @@setup_segfault_handler = Atomic(Bool).new(false)
  @@segfault_handler = LibC::SigactionHandlerT.new { |sig, info, data|
    # Capture fault signals (SEGV, BUS) and finish the process printing a backtrace first

    # This handler must not allocate memory via the GC! Expanding the heap or
    # triggering a GC cycle here could generate another SEGV

    # Determine if the SEGV was inside or 'near' the top of the stack
    # to check for potential stack overflow. 'Near' is a small
    # amount larger than a typical stack frame, 4096 bytes here.
    addr = info.value.si_addr

    is_stack_overflow =
      begin
        stack_top = ::Fiber.current.@stack.pointer - 4096
        stack_bottom = ::Fiber.current.@stack.bottom
        stack_top <= addr < stack_bottom
      rescue e
        Crystal::System.print_error "Error while trying to determine if a stack overflow has occurred. Probable memory corruption\n"
        false
      end

    if is_stack_overflow
      Crystal::System.print_error "Stack overflow (e.g., infinite or very deep recursion)\n"
    else
      Crystal::System.print_error "Invalid memory access (signal %d) at address %p\n", sig, addr
    end

    Exception::CallStack.print_backtrace
    LibC._exit(sig)
  }

  def self.setup_default_handlers : Nil
    return if @@setup_default_handlers.swap(true, :relaxed)
    @@sigset.clear
    start_loop

    {% if flag?(:interpreted) && Interpreter.class.has_method?(:signal_descriptor) %}
      # replace the interpreter's writer pipe with the interpreted, so signals
      # will be received by the interpreter, but handled by the interpreted
      # signal loop
      Crystal::Interpreter.signal_descriptor(@@pipe[1].fd)
    {% else %}
      ::Signal::PIPE.ignore
    {% end %}

    ::Signal::CHLD.reset
  end

  def self.setup_segfault_handler
    return if @@setup_segfault_handler.swap(true, :relaxed)

    altstack = LibC::StackT.new
    altstack.ss_sp = LibC.malloc(LibC::SIGSTKSZ)
    altstack.ss_size = LibC::SIGSTKSZ
    altstack.ss_flags = 0
    LibC.sigaltstack(pointerof(altstack), nil)

    action = LibC::Sigaction.new
    action.sa_flags = LibC::SA_ONSTACK | LibC::SA_SIGINFO
    action.sa_sigaction = @@segfault_handler
    LibC.sigemptyset(pointerof(action.@sa_mask))

    LibC.sigaction(::Signal::SEGV, pointerof(action), nil)
    LibC.sigaction(::Signal::BUS, pointerof(action), nil)
  end
end

struct Crystal::System::Sigset
  {% if flag?(:darwin) || flag?(:openbsd) %}
    @set = LibC::SigsetT.new(0)
  {% else %}
    @set = LibC::SigsetT.new
  {% end %}

  def to_unsafe
    pointerof(@set)
  end

  def <<(signal) : Nil
    LibC.sigaddset(pointerof(@set), signal)
  end

  def delete(signal) : Nil
    LibC.sigdelset(pointerof(@set), signal)
  end

  def includes?(signal) : Bool
    LibC.sigismember(pointerof(@set), signal) == 1
  end

  def clear : Nil
    LibC.sigemptyset(pointerof(@set))
  end
end

module Crystal::System::SignalChildHandler
  # Process#wait will block until the sub-process has terminated. On POSIX
  # systems, the SIGCHLD signal is triggered. We thus always trap SIGCHLD then
  # reap/memorize terminated child processes and eventually notify
  # Process#wait through a channel, that may be created before or after the
  # child process exited.

  @@pending = {} of LibC::PidT => Int32
  @@waiting = {} of LibC::PidT => Channel(Int32)
  @@mutex = Mutex.new(:unchecked)

  def self.wait(pid : LibC::PidT) : Channel(Int32)
    channel = Channel(Int32).new(1)

    @@mutex.lock
    if exit_code = @@pending.delete(pid)
      @@mutex.unlock
      channel.send(exit_code)
      channel.close
    else
      @@waiting[pid] = channel
      @@mutex.unlock
    end

    channel
  end

  def self.call : Nil
    loop do
      pid = LibC.waitpid(-1, out exit_code, LibC::WNOHANG)

      case pid
      when 0
        return
      when -1
        return if Errno.value == Errno::ECHILD
        raise RuntimeError.from_errno("waitpid")
      else
        @@mutex.lock
        if channel = @@waiting.delete(pid)
          @@mutex.unlock
          channel.send(exit_code)
          channel.close
        else
          @@pending[pid] = exit_code
          @@mutex.unlock
        end
      end
    end
  end

  def self.after_fork
    @@pending.clear
    @@waiting.each_value(&.close)
    @@waiting.clear
  end
end
