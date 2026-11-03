zig build -Doptimize=ReleaseFast

hyperfine \
    --shell=default \
    --parameter-list input data_2mb,data_5mb,data_10mb,data_25mb,data_50mb,data_100mb,data_250mb,data_500mb,data_1gb \
    --warmup=3 \
    --export-json output.json \
    "../zig-out/bin/simdjson validate < {input}.json" \
    "../zig-out/bin/simdjson --use-std-lib validate < {input}.json"

# uvx --from 'git+https://github.com/sharkdp/hyperfine' plot_whisker output.json
uv run plot_line.py output.json --throughput
