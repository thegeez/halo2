(def- status-messages
  {100 "Continue"
   101 "Switching Protocols"
   200 "OK"
   201 "Created"
   202 "Accepted"
   203 "Non-Authoritative Information"
   204 "No Content"
   205 "Reset Content"
   206 "Partial Content"
   300 "Multiple Choices"
   301 "Moved Permanently"
   302 "Found"
   303 "See Other"
   304 "Not Modified"
   305 "Use Proxy"
   307 "Temporary Redirect"
   400 "Bad Request"
   401 "Unauthorized"
   402 "Payment Required"
   403 "Forbidden"
   404 "Not Found"
   405 "Method Not Allowed"
   406 "Not Acceptable"
   407 "Proxy Authentication Required"
   408 "Request Time-out"
   409 "Conflict"
   410 "Gone"
   411 "Length Required"
   412 "Precondition Failed"
   413 "Request Entity Too Large"
   414 "Request-URI Too Large"
   415 "Unsupported Media Type"
   416 "Requested range not satisfiable"
   417 "Expectation Failed"
   500 "Internal Server Error"
   501 "Not Implemented"
   502 "Bad Gateway"
   503 "Service Unavailable"
   504 "Gateway Time-out"
   505 "HTTP Version not supported"})


(def- mime-types {"txt" "text/plain"
                  "css" "text/css"
                  "js" "application/javascript"
                  "json" "application/json"
                  "xml" "text/xml"
                  "html" "text/html"
                  "svg" "image/svg+xml"
                  "pg" "image/jpeg"
                  "jpeg" "image/jpeg"
                  "gif" "image/gif"
                  "png" "image/png"
                  "wasm" "application/wasm"
                  "gz" "application/gzip"})

(def CRLF "\r\n")

(def request-peg
  (peg/compile ~{:main (sequence :request-line :crlf (group (some :headers)) :crlf (opt :body))
                 :request-line (sequence (capture (to :sp)) :sp (capture (to :sp)) :sp "HTTP/" (capture (to :crlf)))
                 :header-key (some (if-not (choice ":" :crlf) 1))
                 :headers (sequence (capture :header-key) ": " (capture (to :crlf)) :crlf)
                 :body (capture (some (if-not -1 1)))
                 :sp " "
                 :crlf ,CRLF}))

(def path-peg
  (peg/compile '(capture (some (if-not (choice "?" "#") 1)))))

(defn content-length [req]
  (if-let [content-length-str (or (get-in req [:headers "content-length"])
                                  (get-in req [:headers "Content-Length"]))]
    (scan-number content-length-str)
    0))

(defn expect-header [req]
  (or (get-in req [:headers "Expect"]) (get-in req [:headers "expect"])))

(defn content-type [s]
  (as-> (string/split "." s) _
        (last _)
        (get mime-types _ "text/plain")))

(defn close-connection? [req]
  (let [conn (or (get-in req [:headers "Connection"])
                 (get-in req [:headers "connection"]))]
    (= "close" conn)))


(defn request-headers [parts]
  (var output @{})

  (let [parts (partition 2 parts)]

    (each [k v] parts
      (if (get output k)
        (put output k (string (get output k) "," v))
        (put output k v))))

  output)


(defn request [buf]
  (when-let [parts (peg/match request-peg buf)
             [method uri http-version headers body] parts
             headers (request-headers headers)
             [path] (peg/match path-peg uri)]
    @{:headers headers
      :uri uri
      :method method
      :http-version http-version
      :path path
      :body body}))


(defn http-response-header [header]
  (let [[k v] header]
    (if (indexed? v)
      (string k ": " v (string/join v ","))
      (string k ": " v))))


(defn http-response-headers [headers]
  (as-> (pairs headers) ?
        (map http-response-header ?)
        (string/join ? CRLF)))


(defn file-exists? [str]
  (= :file (os/stat str :mode)))


(defn http-response-string [res]
  (let [status (get res :status 200)
        status-message (get status-messages status "Unknown Status Code")
        body (get res :body "")
        headers (get res :headers @{})
        headers (merge {"Content-Length" (length body)} headers)
        headers (http-response-headers headers)]
    (string "HTTP/1.1 " status " " status-message CRLF
            headers CRLF CRLF
            body)))


(defn http-response
  "Turns a response dictionary into an http response string"
  [response]
  # check for static files
  (if-let [file (get response :file)]
    (let [content-type (content-type file)
          headers (get response :headers {})
          file-exists? (file-exists? file)
          body (if file-exists? (slurp file) "not found")
          status (if file-exists? 200 404)
          gzip? (= "application/gzip" content-type)]
      (http-response-string @{:status status
                              :headers (merge headers {"Content-Type" content-type
                                                       "Content-Encoding" (when gzip? "gzip")})
                              :body body}))
    # regular http responses
    (http-response-string response)))


(defmacro ignore-socket-hangup! [& args]
  ~(try
     ,;args
     ([err fib]
      (unless (or (= err "Connection reset by peer")
                  (= err "timeout"))
        (propagate err fib)))))


(defn connection-handler
  "A function for turning circlet http handlers into stream handlers"
  [handler max-size]
  (def buf (buffer/new 1024))

  (fn [stream]
    (ignore-socket-hangup!
      (defer (do (buffer/clear buf)
                 (:close stream))
        (while (:read stream 1024 buf 7)
          (when-let [request (request buf)
                     content-length (content-length request)
                     request-body (get request :body "")]
            # Early termination / ignore of a request should not drop
            # the connection. This can impact load balancers which
            # reuse connections to the upstream server between their
            # clients.
            (var handled false)
            # If the client is requesting a preflight check on the request
            # Let it continue if it does not exceed the size limit
            # https://datatracker.ietf.org/doc/html/rfc7231#section-5.1.1
            (when (= "100-continue" (expect-header request))
              (if (> content-length max-size)
                (do
                  # Early 413 without consuming the body
                  (:write stream (http-response-string @{:status 413}))
                  (buffer/clear buf)
                  (set handled true)
                )
                # Ideally the application makes this determination
                # But because halo2 buffers the request before sending
                # it to the application handler, halo2 should therefore
                # prompt the client to send the rest of the body without
                # waiting.
                (:write stream (string "HTTP/1.1 100 Continue" CRLF CRLF))))

            # Terminate the request early if it exceeds the size limit
            (when (and (not handled) (> content-length max-size))
              # Clients do not read the response until the full request has been sent
              # The following just overwrites the same buffer over and over
              # Until the expected content-length is consumed
              (var bytes-remaining (- content-length (length (get request :body ""))))
              (buffer/clear buf)
              (while (:read stream (min bytes-remaining 1024) buf 7)
                (set bytes-remaining (- bytes-remaining (length buf)))
                (buffer/clear buf)
                (when (= 0 bytes-remaining) (break)))

              # Respond to the client after the request has been consumed with entity too large
              (:write stream (http-response-string @{:status 413}))
              (set handled true))

            # Read the rest of the request from the socket
            (when (and (not handled) (> content-length (length request-body)))
              (var body-buffer (buffer request-body))
              (var bytes-remaining (- content-length (length body-buffer)))
              # Read from socket until all bytes have been read
              (while (:read stream (min bytes-remaining 1024) body-buffer 7)
                (set bytes-remaining (- content-length (length body-buffer)))
                (when (= 0 bytes-remaining) (break)))
              # Put the buffer back into the body
              (put request :body body-buffer))

            # The buffer can be cleared because it is now on the request.
            (buffer/clear buf)

            # Call the application handler with the completed request
            (when (not handled)
              (as-> (handler request) _
                  (http-response _)
                  (:write stream _)))

            # close connection right away if Connection: close
            (when (close-connection? request)
              (break))))))))


(defn server [handler port &opt host max-size]
  (default host "localhost")
  (default max-size 8192)

  (let [port (string port)
        socket (net/server host port)]

    (forever
      (when-let [conn (:accept socket)]
        (ev/call (connection-handler handler max-size) conn)))))
