// docker run --network host -e ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/x -v $(pwd):/x -w /x envoyproxy/envoy-dev:a27d2c31627e59f096f7c8cdc84488649158b000 --config-path ./envoy.yaml
// zig cc -target aarch64-linux -shared -nostdlib -Wl,--no-undefined -o libhandwritten.so module.S

.section .text
.global envoy_dynamic_module_on_program_init
.global envoy_dynamic_module_on_http_filter_config_new
.global envoy_dynamic_module_on_http_filter_config_destroy
.global envoy_dynamic_module_on_http_filter_new
.global envoy_dynamic_module_on_http_filter_request_headers
.global envoy_dynamic_module_on_http_filter_request_body
.global envoy_dynamic_module_on_http_filter_request_trailers
.global envoy_dynamic_module_on_http_filter_response_headers
.global envoy_dynamic_module_on_http_filter_response_body
.global envoy_dynamic_module_on_http_filter_response_trailers
.global envoy_dynamic_module_on_http_filter_stream_complete
.global envoy_dynamic_module_on_http_filter_destroy

.extern envoy_dynamic_module_callback_http_set_response_header

envoy_dynamic_module_on_program_init:
    adr x0, abi_version // Load the address of the abi_version string.
    ret

envoy_dynamic_module_on_http_filter_config_new:
    ret

envoy_dynamic_module_on_http_filter_config_destroy:
    ret

envoy_dynamic_module_on_http_filter_new:
    ret

envoy_dynamic_module_on_http_filter_request_headers:
    mov x0, #0 // Return the continue status.
    ret

envoy_dynamic_module_on_http_filter_request_body:
    mov x0, #0 // Return the continue status.
    ret

envoy_dynamic_module_on_http_filter_request_trailers:
    mov x0, #0 // Return the continue status.
    ret

envoy_dynamic_module_on_http_filter_response_headers:
    // Move the address of the custom header key and value into registers.
    // header name ptr and length are passed in x1 and x2.
    adr x1, custom_header_key // Load the address of the custom header value.
    mov x2, #3 // Length of the custom header value.
    // header value ptr and length are passed in x3 and x4.
    // The header name is "x-envoy-custom-header" and the value is "hello world".
    adr x3, custom_header_value // Load the address of the custom header key.
    mov x4, #3 // Length of the custom header key.
    // Save the return address the above the stack pointer.
    stp x29, x30, [sp, #-16]! // Push the frame pointer and return address onto the stack.
    // Call the envoy_dynamic_module_callback_http_set_response_header function.
    bl envoy_dynamic_module_callback_http_set_response_header
    // Restore the stack pointer and return address.
    ldp x29, x30, [sp], #16 // Pop the frame pointer and return address from the stack.
    mov x0, #0 // Return the continue status.
    ret

envoy_dynamic_module_on_http_filter_response_body:
    mov x0, #0 // Return the continue status.
    ret

envoy_dynamic_module_on_http_filter_response_trailers:
    mov x0, #0 // Return the continue status.
    ret

envoy_dynamic_module_on_http_filter_stream_complete:
    ret

envoy_dynamic_module_on_http_filter_destroy:
    ret

.section .rodata
abi_version:
    .asciz "cf448e788b7b565ef583167d94489c93320c234224a50fa4a92f096f2467038d"
custom_header_key:
    .asciz "foo"
custom_header_value:
    .asciz "bar"
