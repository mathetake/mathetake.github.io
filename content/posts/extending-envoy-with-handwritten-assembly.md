---
title: "Extending Envoy with Handwritten Assembly"
date: "2025-04-07"
summary: "A deep dive into extending Envoy with handwritten assembly code."
toc: false
readTime: false
autonumber: true
hideBackToTop: true
---

The last week, I gave a talk at EnvoyCon 2025 in London about the brand new ["Dynamic Modules" feature in Envoy](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/advanced/dynamic_modules).
In short, it allows users to load a shared object file into Envoy at runtime, which can be used to extend Envoy's functionality. It
is a pretty cool feature while the fundamental idea is not new at all as we see in the industry such as NGINX modules.

As an author of the feature and a maintainer of Envoy, I am super excited about this feature and I am glad to see that it is finally
available in the latest Envoy release which will be released soon. After the talk, I received a lot of feedback and questions about
it, and was glad to see the amount of interest in the community. 

In this blog post, however, I want to share a weird story about writing a handwritten[^1] assembly code to have some fun. 
Just for having fun, not for any practical purpose obviously ;) On the other hand, this might help you learn exactly what
a dynamic module shared library should look like at the assembly level.

For details of the feature, the official high level documentation is available [here](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/advanced/dynamic_modules) as
well as we host the official examples repository [here](https://github.com/envoyproxy/dynamic-modules-examples).

In this post, I assume that you are on with AArch64 architecture either on Apple Silicon or Linux ARM64.

## What is Dynamic Module

The definition of a dynamic module is a shared object file that can be loaded into Envoy at runtime. To become loadable,
the shared object file must implement the "Envoy Dynamic Module ABI" which is defined in [a pure C header file](https://github.com/envoyproxy/envoy/blob/main/source/extensions/dynamic_modules/abi.h).

Even though Envoy provides an official Rust SDK that abstracts away all the details of the ABI, technically speaking one can
implement the ABI in any language as long as it can produce a shared object file. 
As I worked on the compiler implementation from scratch in my previous project, called [wazero](https://github.com/tetratelabs/wazero),
I know a thing or two about assembly, so I thought it would be a good opportunity to have some fun with assembly language and Envoy.

## Minimal Loadable Module

First, let's create a bare minimum shared object file that can be loaded into Envoy. We begin with the following assembly code, and
compile it with ``zig cc -target aarch64-linux -shared -nostdlib -Wl,--no-undefined -o libhandwritten.so module.S``
```diff
--- /dev/null
+++ b/codes/hand-written-envoy/module.S
@@ -0,0 +1,9 @@
+
+.section .text
+.global envoy_dynamic_module_on_program_init
+
+envoy_dynamic_module_on_program_init:
+    mov x0, 0 // Retrun null pointer.
+    ret
```

where we define `envoy_dynamic_module_on_program_init` function which is the entry point of the dynamic module to be called
by Envoy when the module is loaded.

You will get the shared object file `libhandwritten.so` whose target is `aarch64-linux`:

```
$ file libhandwritten.so 
libhandwritten.so: ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), static-pie linked, with debug_info, not stripped
```

Now let's run it with Envoy. You can use the following command to run Envoy with the shared object file:

```yaml
static_resources:
  listeners:
    - address:
        socket_address:
          address: 0.0.0.0
          port_value: 1062
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress_http
                route_config:
                  virtual_hosts:
                    - name: local_route
                      domains:
                        - "*"
                      routes:
                        - match:
                            prefix: "/"
                          route:
                            cluster: httpbin
                http_filters:
                  - name: handwritten-module
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.dynamic_modules.v3.DynamicModuleFilter
                      dynamic_module_config:
                        name: handwritten
                      filter_name: handwritten
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
    - name: httpbin
      connect_timeout: 5000s
      type: strict_dns
      lb_policy: round_robin
      load_assignment:
        cluster_name: httpbin
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: httpbin.org
                      port_value: 80
```

where we specify the module named `handwritten` in the `dynamic_module_config` field. Envoy will look for a shared object file
with the name `libhandwritten.so` in the path specified by the `ENVOY_DYNAMIC_MODULES_SEARCH_PATH` environment variable like
`LD_LIBRARY_PATH` in Linux.

Let's run Envoy with the shared object file. You can use the following command 

```
docker run --rm --network host -e ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/x -v $(pwd):/x -w /x envoyproxy/envoy-dev:a27d2c31627e59f096f7c8cdc84488649158b000 --config-path ./envoy.yaml
```

then you will see the following error message:

```
[2025-04-07 11:42:34.675][1][critical][main] [source/server/server.cc:422] error initializing config '  ./envoy.yaml': Failed to load dynamic module: Failed to initialize dynamic module: /x/libhandwritten.so
```

where you can see that Envoy failed to load the shared object file. The reason is that `envoy_dynamic_module_on_program_init` function is,
[according to the ABI definition](https://github.com/envoyproxy/envoy/blob/8ed2dc503b8f665345f013645e690a714a8f8036/source/extensions/dynamic_modules/abi.h#L235-L237),
supposed to return a null-terminated pointer to the ABI version string, otherwise Envoy will fail to load the module.

To fix this, we need to return a non-null pointer. Let's modify the assembly code to return some random string

```diff
--- a/codes/hand-written-envoy/module.S
+++ b/codes/hand-written-envoy/module.S
@@ -5,5 +5,9 @@
 .global envoy_dynamic_module_on_program_init
 
 envoy_dynamic_module_on_program_init:
-    mov x0, 0 // Retrun null pointer.
+    adr x0, abi_version // Load the address of the abi_version string.
     ret
+
+.section .rodata
+abi_version:
+    .asciz "some_version_string"
```

where we define a new section `.rodata` which is a read-only data section, and define a string `abi_version` in the section.
Then we load the address of the string into `x0` register and return it (x0 is the first result register in AArch64 calling convention!).

Now let's run Envoy again with the shared object file:

```
[2025-04-07 11:44:58.529][1][critical][main] [source/server/server.cc:422] error initializing config '  ./envoy.yaml': Failed to load dynamic module: ABI version mismatch: got some_version_string, but expected cf448e788b7b565ef583167d94489c93320c234224a50fa4a92f096f2467038d
```

where you see that it failed to load the module again, but this time the error message is different. 
The reason is that Envoy expects the ABI version string to be `cf448e78...` 
which is the hash of the ABI version string defined from the ABI header file.

Let's further modify the assembly code to return the ABI version string:

```diff
--- a/codes/hand-written-envoy/module.S
+++ b/codes/hand-written-envoy/module.S
@@ -10,4 +10,4 @@ envoy_dynamic_module_on_program_init:
 
 .section .rodata
 abi_version:
-    .asciz "some_version_string"
+    .asciz "cf448e788b7b565ef583167d94489c93320c234224a50fa4a92f096f2467038d"
```

where we return the ABI version string as the return value of the function. Note that this version string is 
Envoy-version specific, so you need to check the ABI version string from the Envoy source code.
Now let's run Envoy again with the shared object file:

```
[2025-04-07 11:45:18.426][1][critical][main] [source/server/server.cc:422] error initializing config '  ./envoy.yaml': Failed to create filter config: Failed to resolve symbol envoy_dynamic_module_on_http_filter_config_new
```

where now Envoy stopped complaining about the initialization of the module, but it failed to resolve the symbol `envoy_dynamic_module_on_http_filter_config_new`.
What basically it complains is that some "required functions" are missing in the shared object file. Let's add
skeletons of all the required functions to the assembly code:

```diff
--- a/codes/hand-written-envoy/module.S
+++ b/codes/hand-written-envoy/module.S
@@ -3,11 +3,61 @@
 
 .section .text
 .global envoy_dynamic_module_on_program_init
+.global envoy_dynamic_module_on_http_filter_config_new
+.global envoy_dynamic_module_on_http_filter_config_destroy
+.global envoy_dynamic_module_on_http_filter_new
+.global envoy_dynamic_module_on_http_filter_request_headers
+.global envoy_dynamic_module_on_http_filter_request_body
+.global envoy_dynamic_module_on_http_filter_request_trailers
+.global envoy_dynamic_module_on_http_filter_response_headers
+.global envoy_dynamic_module_on_http_filter_response_body
+.global envoy_dynamic_module_on_http_filter_response_trailers
+.global envoy_dynamic_module_on_http_filter_stream_complete
+.global envoy_dynamic_module_on_http_filter_destroy
 
 envoy_dynamic_module_on_program_init:
     adr x0, abi_version // Load the address of the abi_version string.
     ret
 
+envoy_dynamic_module_on_http_filter_config_new:
+    ret
+
+envoy_dynamic_module_on_http_filter_config_destroy:
+    ret
+
+envoy_dynamic_module_on_http_filter_new:
+    ret
+
+envoy_dynamic_module_on_http_filter_request_headers:
+    mov x0, #0 // Return the continue status.
+    ret
+
+envoy_dynamic_module_on_http_filter_request_body:
+    mov x0, #0 // Return the continue status.
+    ret
+
+envoy_dynamic_module_on_http_filter_request_trailers:
+    mov x0, #0 // Return the continue status.
+    ret
+
+envoy_dynamic_module_on_http_filter_response_headers:
+    mov x0, #0 // Return the continue status.
+    ret
+
+envoy_dynamic_module_on_http_filter_response_body:
+    mov x0, #0 // Return the continue status.
+    ret
+
+envoy_dynamic_module_on_http_filter_response_trailers:
+    mov x0, #0 // Return the continue status.
+    ret
+
+envoy_dynamic_module_on_http_filter_stream_complete:
+    ret
+
+envoy_dynamic_module_on_http_filter_destroy:
+    ret
+
```

All of these functions are called "Event Hooks" which are called by Envoy when the corresponding events happen.
For example, `envoy_dynamic_module_on_http_filter_request_headers` is called when the request headers are received,
and `envoy_dynamic_module_on_http_filter_response_headers` is called when the response headers are received.

This will make the shared object file completely loadable into Envoy and the docker command will run successfully.
In fact, the curl command `curl localhost:1062/uuid -v` should succeed and return a 200 OK response.

## Add Custom Logic

Let's do something more interesting like for example, adding a custom response header to the response.
To do this, we need to modify the `envoy_dynamic_module_on_http_filter_response_headers` function to add a custom response header.
Setting a custom response header can be done by a "callback" function implemented in the Envoy side called `envoy_dynamic_module_callback_http_set_response_header`.

To use the callback function, we need to declare the external function in the assembly code first:

```diff
--- a/codes/hand-written-envoy/module.S
+++ b/codes/hand-written-envoy/module.S
@@ -15,6 +15,8 @@
 .global envoy_dynamic_module_on_http_filter_stream_complete
 .global envoy_dynamic_module_on_http_filter_destroy
 
+.extern envoy_dynamic_module_callback_http_set_response_header
+
 envoy_dynamic_module_on_program_init:
     adr x0, abi_version // Load the address of the abi_version string.
     ret
```

This allows us to resolve the address of the Envoy-side callback function's address. Then, let's modify the
`envoy_dynamic_module_on_http_filter_response_headers` function to call the callback function:

```diff
--- a/codes/hand-written-envoy/module.S
+++ b/codes/hand-written-envoy/module.S
@@ -41,6 +43,20 @@ envoy_dynamic_module_on_http_filter_request_trailers:
     ret
 
 envoy_dynamic_module_on_http_filter_response_headers:
+    // Move the address of the custom header key and value into registers.
+    // header name ptr and length are passed in x1 and x2.
+    adr x1, custom_header_name // Load the address of the custom header value.
+    mov x2, #3 // Length of the custom header value.
+    // header value ptr and length are passed in x3 and x4.
+    // The header name is "x-envoy-custom-header" and the value is "hello world".
+    adr x3, custom_header_value // Load the address of the custom header key.
+    mov x4, #3 // Length of the custom header key.
+    // Save the return address the above the stack pointer.
+    stp x29, x30, [sp, #-16]! // Push the frame pointer and return address onto the stack.
+    // Call the envoy_dynamic_module_callback_http_set_response_header function.
+    bl envoy_dynamic_module_callback_http_set_response_header
+    // Restore the stack pointer and return address.
+    ldp x29, x30, [sp], #16 // Pop the frame pointer and return address from the stack.
     mov x0, #0 // Return the continue status.
     ret
 
@@ -61,3 +77,7 @@ envoy_dynamic_module_on_http_filter_destroy:
 .section .rodata
 abi_version:
     .asciz "cf448e788b7b565ef583167d94489c93320c234224a50fa4a92f096f2467038d"
+custom_header_name:
+    .asciz "foo"
+custom_header_value:
+    .asciz "bar"
```

where we do two things. First, in the bottom of the file, we define two strings `custom_header_name` and `custom_header_value` 
which are the key and value of the custom header. In this case, we set the name to `foo` and the value to `bar`.
In the `envoy_dynamic_module_on_http_filter_response_headers` function, we call the callback function named 
`envoy_dynamic_module_callback_http_set_response_header`. [This function takes five arguments](https://github.com/envoyproxy/envoy/blob/8ed2dc503b8f665345f013645e690a714a8f8036/source/extensions/dynamic_modules/abi.h#L604-L612):
- `x0`: the filter pointer which is identical with the first argument passed to `envoy_dynamic_module_on_http_filter_response_headers`, so we don't need to do anything.
- `x1`: the address of the custom header key.
- `x2`: the length of the custom header key.
- `x3`: the address of the custom header value.
- `x4`: the length of the custom header value.

After we prepare these arguments, we also need to save the return address to the stack and call the callback function. I left the
detail of each assembly in the comments, so please refer to the comments for more details.

Now let's run Envoy again with the shared object file and execute the curl command:

```
$ curl localhost:1062 --head     
HTTP/1.1 200 OK
date: Mon, 07 Apr 2025 19:11:30 GMT
content-type: text/html; charset=utf-8
content-length: 9593
server: envoy
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 1336
foo: bar
```

where you should see the custom header `foo: bar` in the response headers, which means our handwritten assembly code
successfully added a custom response header to the response.

## Conclusion

In this post, I shared a story about how I wrote a handwritten assembly code to extend Envoy with a custom response header.
Writing assembly in any way is not a practical way to extend Envoy, but this post might be helpful for those who are curious to
understand how the Envoy dynamic module works at the assembly level. The complete code I wrote in this post is available
[here](https://github.com/mathetake/mathetake.github.io/tree/main/codes/hand-written-envoy).

The dynamic modules feature is a powerful feature, but it's still under development and not all the features are implemented yet.
If you are interested in the feature, please feel free to join the community at #envoy-dynamic-modules channel on Envoy Slack or
directly reach out to me on X or GitHub. I am happy to help you with any questions or issues you may have.

See you next time!

[^1]: I tried generating all the assembly code with "AI" but it miserably failed