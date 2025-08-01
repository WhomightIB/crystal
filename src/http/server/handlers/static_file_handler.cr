require "ecr/macros"
require "html"
require "uri"
require "mime"

# A handler that lists directories and serves files under a given public directory.
#
# This handler can send precompressed content, if the client accepts it, and a file
# with the same name and `.gz` extension appended is found in the same directory.
# Precompressed files are only served if they are newer than the original file.
#
# NOTE: To use `StaticFileHandler`, you must explicitly import it with `require "http"`
class HTTP::StaticFileHandler
  include HTTP::Handler

  # In some file systems, using `gz --keep` to compress the file will keep the
  # modification time of the original file but truncating some decimals. We
  # serve the gzipped file nonetheless if the .gz file is modified by a duration
  # of `TIME_DRIFT` before the original file. This value should match the
  # granularity of the underlying file system's modification times
  private TIME_DRIFT = 10.milliseconds

  @public_dir : Path

  # Creates a handler that will serve files in the given *public_dir*, after
  # expanding it (using `File#expand_path`).
  #
  # If *fallthrough* is `false`, this handler does not call next handler when
  # request method is neither GET or HEAD, then serves `405 Method Not Allowed`.
  # Otherwise, it calls next handler.
  #
  # If *directory_listing* is `false`, directory listing is disabled. This means that
  # paths matching directories are ignored and next handler is called.
  def initialize(public_dir : String, @fallthrough : Bool = true, @directory_listing : Bool = true)
    @public_dir = Path.new(public_dir).expand
  end

  # :ditto:
  @[Deprecated]
  def self.new(public_dir : String, fallthrough = true, directory_listing = true)
    new(public_dir, fallthrough: !!fallthrough, listing: !!listing)
  end

  def call(context) : Nil
    check_request_method!(context) || return

    request_path = request_path(context)

    check_request_path!(context, request_path) || return

    request_path = Path.posix(request_path)
    expanded_path = request_path.expand("/")

    file_info, file_path = file_info(expanded_path)

    if normalized_path = normalize_request_path(context, request_path, expanded_path, file_info)
      return redirect_to context, normalized_path
    end

    return call_next(context) unless file_info

    if file_info.directory?
      directory_index(context, request_path, file_path)
    elsif file_info.file?
      serve_file_with_cache(context, file_info, file_path)
    else # Not a normal file (FIFO/device/socket)
      call_next(context)
    end
  end

  private def check_request_method!(context : Server::Context) : Bool
    return true if context.request.method.in?("GET", "HEAD")

    if @fallthrough
      call_next(context)
    else
      context.response.status = :method_not_allowed
      context.response.headers.add("Allow", "GET, HEAD")
    end

    false
  end

  private def check_request_path!(context : Server::Context, request_path : String) : Bool
    # File path cannot contain '\0' (NUL) because all filesystem I know
    # don't accept '\0' character as file name.
    if request_path.includes? '\0'
      context.response.respond_with_status(:bad_request)
      return false
    end

    true
  end

  private def normalize_request_path(context : Server::Context, request_path : Path, expanded_path : Path, file_info) : Path?
    if @directory_listing && file_info.try(&.directory?) && !request_path.ends_with_separator?
      # Append / to path if missing
      expanded_path.join("")
    elsif request_path != expanded_path
      expanded_path
    end
  end

  private def file_info(expanded_path : Path)
    file_path = @public_dir.join(expanded_path.to_kind(Path::Kind.native))

    {File.info?(file_path), file_path}
  end

  private def serve_file_with_cache(context : Server::Context, file_info, file_path : Path)
    last_modified = file_info.modification_time
    add_cache_headers(context.response.headers, last_modified)

    if cache_request?(context, last_modified)
      context.response.status = :not_modified
      return
    end

    serve_file_compressed(context, file_info, file_path, last_modified)
  end

  private def serve_file_compressed(context : Server::Context, file_info, file_path : Path, last_modified : Time)
    original_file_path = file_path

    # Checks if pre-gzipped file can be served
    if context.request.headers.includes_word?("Accept-Encoding", "gzip")
      gz_file_path = Path["#{file_path}.gz"]

      if (gz_file_info = File.info?(gz_file_path)) &&
         last_modified - gz_file_info.modification_time < TIME_DRIFT
        file_path = gz_file_path
        file_info = gz_file_info
        context.response.headers["Content-Encoding"] = "gzip"
      end
    end

    serve_file(context, file_info, file_path, original_file_path, last_modified)
  end

  private def serve_file(context : Server::Context, file_info, file_path : Path, original_file_path : Path, last_modified : Time)
    context.response.content_type = MIME.from_filename(original_file_path.to_s, "application/octet-stream")

    File.open(file_path) do |file|
      if range_header = context.request.headers["Range"]?
        serve_file_range(context, file, range_header, file_info)
      else
        context.response.headers["Accept-Ranges"] = "bytes"

        serve_file_full(context, file, file_info)
      end
    end
  end

  private def serve_file_range(context : Server::Context, file : File, range_header : String, file_info)
    range_header = range_header.lchop?("bytes=")
    unless range_header
      context.response.headers["Content-Range"] = "bytes */#{file_info.size}"
      context.response.status = :range_not_satisfiable
      context.response.close
      return
    end

    ranges = parse_ranges(range_header, file_info.size)
    unless ranges
      context.response.respond_with_status :bad_request
      return
    end

    if file_info.size.zero? && ranges.size == 1 && ranges[0].begin.zero?
      context.response.status = :ok
      return
    end

    # If any of the ranges start beyond the end of the file, we return an
    # HTTP 416 Range Not Satisfiable.
    # See https://www.rfc-editor.org/rfc/rfc9110.html#section-14.1.2-11.1
    if ranges.any? { |range| range.begin >= file_info.size }
      context.response.headers["Content-Range"] = "bytes */#{file_info.size}"
      context.response.status = :range_not_satisfiable
      context.response.close
      return
    end

    ranges.map! { |range| range.begin..(Math.min(range.end, file_info.size - 1)) }

    context.response.status = :partial_content

    if ranges.size == 1
      range = ranges.first
      file.seek range.begin
      context.response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{file_info.size}"
      IO.copy file, context.response, range.size
    else
      MIME::Multipart.build(context.response) do |builder|
        content_type = context.response.headers["Content-Type"]?
        context.response.headers["Content-Type"] = builder.content_type("byterange")

        ranges.each do |range|
          file.seek range.begin
          headers = HTTP::Headers{
            "Content-Range"  => "bytes #{range.begin}-#{range.end}/#{file_info.size}",
            "Content-Length" => range.size.to_s,
          }
          headers["Content-Type"] = content_type if content_type
          chunk_io = IO::Sized.new(file, range.size)
          builder.body_part headers, chunk_io
        end
      end
    end
  end

  private def serve_file_full(context : Server::Context, file : File, file_info)
    context.response.status = :ok
    context.response.content_length = file_info.size
    IO.copy(file, context.response)
  end

  # TODO: Optimize without lots of intermediary strings
  private def parse_ranges(header, file_size)
    ranges = [] of Range(Int64, Int64)
    header.split(",") do |range|
      start_string, dash, finish_string = range.lchop(' ').partition("-")
      return if dash.empty?
      start = start_string.to_i64?
      return if start.nil? && !start_string.empty?
      if finish_string.empty?
        return if start_string.empty?
        finish = file_size
      else
        finish = finish_string.to_i64? || return
      end
      if file_size.zero?
        # > When a selected representation has zero length, the only satisfiable
        # > form of range-spec in a GET request is a suffix-range with a non-zero suffix-length.

        if start
          # This return value signals an unsatisfiable range.
          return [1_i64..0_i64]
        elsif finish <= 0
          return
        else
          start = finish = 0_i64
        end
      elsif !start
        # suffix-range
        start = {file_size - finish, 0_i64}.max
        finish = file_size - 1
      end

      range = (start..finish)
      return unless 0 <= range.begin <= range.end
      ranges << range
    end
    ranges unless ranges.empty?
  end

  private def request_path(context : Server::Context) : String
    original_path = context.request.path.not_nil!

    request_path(URI.decode(original_path))
  end

  # given a full path of the request, returns the path
  # of the file that should be expanded at the public_dir
  protected def request_path(path : String) : String
    path
  end

  private def redirect_to(context : Server::Context, path)
    uri = context.request.uri.dup
    uri.path = URI.encode_path(path.to_s)
    context.response.redirect uri
  end

  private def add_cache_headers(response_headers : HTTP::Headers, last_modified : Time) : Nil
    response_headers["Etag"] = etag(last_modified)
    response_headers["Last-Modified"] = HTTP.format_time(last_modified)
  end

  private def cache_request?(context : HTTP::Server::Context, last_modified : Time) : Bool
    # According to RFC 7232:
    # A recipient must ignore If-Modified-Since if the request contains an If-None-Match header field
    if if_none_match = context.request.if_none_match
      match = {"*", context.response.headers["Etag"]}
      if_none_match.any? { |etag| match.includes?(etag) }
    elsif if_modified_since = context.request.headers["If-Modified-Since"]?
      header_time = HTTP.parse_time(if_modified_since)
      # File mtime probably has a higher resolution than the header value.
      # An exact comparison might be slightly off, so we add 1s padding.
      # Static files should generally not be modified in subsecond intervals, so this is perfectly safe.
      # This might be replaced by a more sophisticated time comparison when it becomes available.
      !!(header_time && last_modified <= header_time + 1.second)
    else
      false
    end
  end

  private def etag(modification_time)
    %{W/"#{modification_time.to_unix}"}
  end

  record DirectoryListing, request_path : String, path : String do
    def each_entry(&)
      Dir.each_child(path) do |entry|
        yield entry
      end
    end

    ECR.def_to_s "#{__DIR__}/static_file_handler.html"
  end

  private def directory_index(context : Server::Context, request_path : Path, path : Path)
    unless @directory_listing
      return call_next(context)
    end

    context.response.content_type = "text/html; charset=utf-8"
    directory_listing(context.response, request_path, path)
  end

  private def directory_listing(io : IO, request_path : Path, path : Path)
    DirectoryListing.new(request_path.to_s, path.to_s).to_s(io)
  end
end
