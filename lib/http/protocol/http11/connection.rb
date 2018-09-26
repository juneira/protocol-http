# Copyright, 2018, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative '../error'

module HTTP
	module Protocol
		module HTTP11
			class Connection
				CRLF = "\r\n".freeze
				CONNECTION = 'connection'.freeze
				HOST = 'host'.freeze
				CLOSE = 'close'.freeze
				VERSION = "HTTP/1.1".freeze
				
				def initialize(io, persistent = true)
					@io = io
					
					@persistent = persistent
				end
				
				attr :io
				attr :persistent
				
				def persistent?(headers)
					if connection = headers[CONNECTION]
						return !connection.include?(CLOSE)
					else
						return true
					end
				end
				
				# @return [Async::Wrapper] the underlying non-blocking IO.
				def hijack
					@persistent = false
					
					@io.flush
					
					return @io
				end
				
				def write_persistent_header
					@io.write("connection: keep-alive\r\n") if @persistent
				end
				
				def close
					@io.close
				end
				
				def each_line(&block)
					@io.each_line(CRLF, chomp: true, &block)
				end
				
				def read_line
					self.each_line do |line|
						return line
					end
				end
				
				def write_request(authority, method, path, version, headers)
					@io.write("#{method} #{path} #{version}\r\n")
					@io.write("host: #{authority}\r\n")
					
					write_headers(headers)
					
					@io.flush
				end
				
				def write_headers(headers)
					headers.each do |name, value|
						@io.write("#{name}: #{value}\r\n")
					end
				end
				
				# @return [Array] The method, target, and version of the request.
				def read_request
					self.read_line.split(/\s+/, 3)
				end
				
				def read_headers
					fields = []
					
					self.each_line do |line|
						if line =~ /^([a-zA-Z\-\d]+):\s*(.+?)\s*$/
							fields << [$1, $2]
						else
							break
						end
					end
					
					return Headers.new(fields)
				end
				
				def read_chunk
					length = self.read_line.to_i(16)
					
					if length == 0
						self.read_line
						
						return nil
					end
					
					# Read the data:
					chunk = @io.read(length)
					
					# Consume the trailing CRLF:
					crlf = @io.read(2)
					
					return chunk
				end
				
				def write_chunk(chunk)
					if chunk.nil?
						@io.write("0\r\n\r\n")
					elsif !chunk.empty?
						@io.write("#{chunk.bytesize.to_s(16).upcase}\r\n")
						@io.write(chunk)
						@io.write(CRLF)
						@io.flush
					end
				end
				
				def write_empty_body(body)
					# Write empty body:
					write_persistent_header
					@io.write("content-length: 0\r\n\r\n")
					
					body.read if body
					
					@io.flush
				end
				
				def write_fixed_length_body(body, length)
					write_persistent_header
					@io.write("content-length: #{length}\r\n\r\n")
					
					chunk_length = 0
					body.each do |chunk|
						chunk_length += chunk.bytesize
						
						if chunk_length > length
							raise ArgumentError, "Trying to write #{chunk_length} bytes, but content length was #{length} bytes!"
						end
						
						@io.write(chunk)
					end
					
					@io.flush
					
					if chunk_length != length
						raise ArgumentError, "Wrote #{chunk_length} bytes, but content length was #{length} bytes!"
					end
				end
				
				def write_chunked_body(body)
					write_persistent_header
					@io.write("transfer-encoding: chunked\r\n\r\n")
					
					body.each do |chunk|
						next if chunk.size == 0
						
						@io.write("#{chunk.bytesize.to_s(16).upcase}\r\n")
						@io.write(chunk)
						@io.write(CRLF)
						@io.flush
					end
					
					@io.write("0\r\n\r\n")
					@io.flush
				end
				
				def write_body_and_close(body)
					# We can't be persistent because we don't know the data length:
					@persistent = false
					write_persistent_header
					
					@io.write("\r\n")
					
					body.each do |chunk|
						@io.write(chunk)
						@io.flush
					end
					
					@io.io.close_write
				end
				
				def write_body(body, chunked = true)
					if body.nil? or body.empty?
						write_empty_body(body)
					elsif length = body.length
						write_fixed_length_body(body, length)
					elsif chunked
						write_chunked_body(body)
					else
						write_body_and_close(body)
					end
				end
				
				def write_body_head(body)
					write_persistent_header
					
					if body.nil? or body.empty?
						@io.write("content-length: 0\r\n\r\n")
					elsif length = body.length
						@io.write("content-length: #{length}\r\n\r\n")
					else
						@io.write("\r\n")
					end
				end
				
				def read_chunked_body
					buffer = String.new.b
					
					while chunk = read_chunk
						buffer << chunk
						chunk.clear
					end
					
					return buffer
				end
				
				def read_fixed_body(length)
					@io.read(length)
				end
				
				def read_tunnel_body
					read_remainder_body
				end
				
				def read_remainder_body
					@io.read
				end
				
				HEAD = "HEAD".freeze
				CONNECT = "CONNECT".freeze
				
				def read_response_body(method, status, headers)
					# RFC 7230 3.3.3
					# 1.  Any response to a HEAD request and any response with a 1xx
					# (Informational), 204 (No Content), or 304 (Not Modified) status
					# code is always terminated by the first empty line after the
					# header fields, regardless of the header fields present in the
					# message, and thus cannot contain a message body.
					if method == "HEAD" or status == 204 or status == 304
						return nil
					end
					
					# 2.  Any 2xx (Successful) response to a CONNECT request implies that
					# the connection will become a tunnel immediately after the empty
					# line that concludes the header fields.  A client MUST ignore any
					# Content-Length or Transfer-Encoding header fields received in
					# such a message.
					if method == "CONNECT" and status == 200
						return read_tunnel_body
					end
					
					if body = read_body(headers)
						return body
					else
						# 7.  Otherwise, this is a response message without a declared message
						# body length, so the message body length is determined by the
						# number of octets received prior to the server closing the
						# connection.
						return read_remainder_body
					end
				end
				
				def read_request_body(headers)
					# 6.  If this is a request message and none of the above are true, then
					# the message body length is zero (no message body is present).
					if body = read_body(headers)
						return body
					end
				end
				
				def read_body(headers)
					# 3.  If a Transfer-Encoding header field is present and the chunked
					# transfer coding (Section 4.1) is the final encoding, the message
					# body length is determined by reading and decoding the chunked
					# data until the transfer coding indicates the data is complete.
					if transfer_encoding = headers[TRANSFER_ENCODING]
						# If a message is received with both a Transfer-Encoding and a
						# Content-Length header field, the Transfer-Encoding overrides the
						# Content-Length.  Such a message might indicate an attempt to
						# perform request smuggling (Section 9.5) or response splitting
						# (Section 9.4) and ought to be handled as an error.  A sender MUST
						# remove the received Content-Length field prior to forwarding such
						# a message downstream.
						if headers[CONTENT_LENGTH]
							raise BadRequest, "Message contains both transfer encoding and content length!"
						end
						
						if transfer_encoding.last == CHUNKED
							return read_chunked_body
						else
							# If a Transfer-Encoding header field is present in a response and
							# the chunked transfer coding is not the final encoding, the
							# message body length is determined by reading the connection until
							# it is closed by the server.  If a Transfer-Encoding header field
							# is present in a request and the chunked transfer coding is not
							# the final encoding, the message body length cannot be determined
							# reliably; the server MUST respond with the 400 (Bad Request)
							# status code and then close the connection.
							return read_body_remainder
						end
					end

					# 5.  If a valid Content-Length header field is present without
					# Transfer-Encoding, its decimal value defines the expected message
					# body length in octets.  If the sender closes the connection or
					# the recipient times out before the indicated number of octets are
					# received, the recipient MUST consider the message to be
					# incomplete and close the connection.
					if content_length = headers[CONTENT_LENGTH]
						length = Integer(content_length)
						if length >= 0
							return read_fixed_body(length)
						else
							raise BadRequest, "Invalid content length: #{content_length}"
						end
					end
				end
			end
		end
	end
end