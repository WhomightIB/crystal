# This module can be included in any `Exception` subclass that is
# used to wrap some system error (`Errno` or `WinError`).
#
# It adds an `os_error` property that contains the original system error.
# It provides several constructor methods that set the `os_error` value:
# * `.from_os_error` receives an OS error value and creates an instance with that.
# * `.from_errno` constructs an instance with the current LibC errno value (`Errno.value`).
# * `.from_winerror` constructs an instance with the current LibC winerror value (`WinError.value`).
#
# An error message is automatically constructed based on the system error message.
#
# For example:
# ```
# class MyError < Exception
#   include SystemError
# end
#
# MyError.from_errno("Something happened")
# ```
#
# ## Customization
#
# Including classes my override several protected methods to customize the
# instance creation based on OS errors:
#
# * `protected def build_message(message, **opts)`
#   Prepares the message that goes before the system error description.
#   By default it returns the original message unchanged. But that could be
#   customized based on the keyword arguments passed to `from_errno` or `from_winerror`.
# * `protected def new_from_os_error(message : String?, os_error, **opts)`
#   Creates an instance of the exception that wraps a system error.
#   This is a factory method and by default it creates an instance
#   of the current class. It can be overridden to generate different
#   classes based on the `os_error` value or keyword arguments.
# * `protected def os_error_message(os_error : Errno | WinError | Nil, **opts) : String?`
#   Returns the respective error message for *os_error*.
#   By default it returns the result of `Errno#message` or `WinError#message`.
#   This method can be overridden for customization of the error message based
#   on *os_error* and *opts*.
module SystemError
  macro included
    extend ::SystemError::ClassMethods

    # The following are macros so we can get the `errno` or `winerror` _before_
    # evaluating `message` and `opts` that may change the `errno` or `winerror` value.

    # Builds an instance of the exception from the current system error value (`Errno.value`).
    #
    # The system message corresponding to the OS error value amends the *message*.
    # Additional keyword arguments are forwarded to the exception initializer `.new_from_os_error`.
    macro from_errno(message, **opts)
      %errno = ::Errno.value
      ::\{{ @type }}.from_os_error(\{{ message }}, %errno, \{{ opts.double_splat }})
    end

    @[Deprecated("Use `.from_os_error` instead")]
    macro from_errno(message = nil, errno = nil, **opts)
      ::\{{ @type }}.from_os_error(\{{ message }}, \{{ errno }}, \{{ opts.double_splat }})
    end

    # Builds an instance of the exception from the current windows error value (`WinError.value`).
    #
    # The system message corresponding to the OS error value amends the *message*.
    # Additional keyword arguments are forwarded to the exception initializer `.new_from_os_error`.
    macro from_winerror(message, **opts)
      %error = ::WinError.value
      ::\{{ @type }}.from_os_error(\{{ message }}, %error, \{{ opts.double_splat }})
    end

    # Builds an instance of the exception from the current Windows Socket API error value (`WinError.wsa_value`).
    #
    # The system message corresponding to the OS error value amends the *message*.
    # Additional keyword arguments are forwarded to the exception initializer.
    macro from_wsa_error(message = nil, **opts)
      %error = ::WinError.wsa_value
      ::\{{ @type }}.from_os_error(\{{ message }}, %error, \{{ opts.double_splat }})
    end

    {% if flag?(:win32) %}
      @[Deprecated("Use `.from_os_error` instead")]
      macro from_winerror(message, winerror, **opts)
        ::\{{ @type }}.from_os_error(\{{ message }}, \{{ winerror }}, \{{ opts.double_splat }})
      end

      @[Deprecated("Use `.from_os_error` instead")]
      macro from_winerror(*, winerror = ::WinError.value, **opts)
        ::\{{ @type }}.from_os_error(nil, \{{ winerror }}, \{{ opts.double_splat }})
      end
    {% end %}
  end

  # The original system error wrapped by this exception
  getter os_error : Errno | WinError | WasiError | Nil

  # :nodoc:
  protected def os_error=(@os_error)
  end

  module ClassMethods
    # Builds an instance of the exception from an *os_error* value.
    #
    # The system message corresponding to the OS error value amends the *message*.
    # Additional keyword arguments are forwarded to the exception initializer `.new_from_os_error`.
    def from_os_error(message : String?, os_error : Errno | WinError | WasiError | Nil, **opts)
      message = self.build_message(message, **opts)
      message =
        if message
          "#{message}: #{os_error_message(os_error, **opts)}"
        else
          os_error_message(os_error, **opts)
        end

      self.new_from_os_error(message, os_error, **opts).tap do |e|
        e.os_error = os_error
      end
    end

    # Prepares the message that goes before the system error description.
    #
    # By default it returns the original message unchanged. But that could be
    # customized based on the keyword arguments passed to `from_errno` or `from_winerror`.
    protected def build_message(message : String?, **opts) : String?
      message
    end

    # Returns the respective error message for *os_error*.
    #
    # By default it returns the result of `Errno#message` or `WinError#message`.
    # This method can be overridden for customization of the error message based
    # on *or_error*  and *\*\*opts*.
    protected def os_error_message(os_error : Errno | WinError | WasiError | Nil, **opts) : String?
      os_error.try &.message
    end

    # Creates an instance of the exception that wraps a system error.
    #
    # This is a factory method and by default it creates an instance
    # of the current class. It can be overridden to generate different
    # classes based on the `os_error` value or keyword arguments.
    protected def new_from_os_error(message : String?, os_error, **opts)
      self.new(message, **opts)
    end
  end
end
