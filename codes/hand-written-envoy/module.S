// docker run --network host -e ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/x -v $(pwd):/x -w /x envoyproxy/envoy-dev:a27d2c31627e59f096f7c8cdc84488649158b000 --config-path ./envoy.yaml
// zig cc -target aarch64-linux -shared -nostdlib -Wl,--no-undefined -o libhandwritten.so module.S

.section .text
.global envoy_dynamic_module_on_program_init

envoy_dynamic_module_on_program_init:
    mov x0, 0 // Retrun null pointer.
    ret
