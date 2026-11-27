# Data from https://fastjsonviewer.com/json-generator.html

zig build -Doptimize=ReleaseFast

rm -rf output.json *.png

 hyperfine \
     --shell=default \
     --parameter-list input data_1kb,data_10kb,data_50kb,data_100kb,data_250kb,data_500kb,data_1mb,data_2mb,data_5mb,data_10mb,data_25mb,data_50mb,data_100mb,data_250mb,data_500mb,data_1gb,data_1900mb \
     --warmup=3 \
     --export-json output.json \
     "../zig-out/bin/simdjson validate < {input}.json" \
     "../zig-out/bin/simdjson --use-std-lib validate < {input}.json" # \

 uv run plot_line.py output.json --throughput --output validate.png

 hyperfine \
     --shell=default \
     --parameter-list input data_1kb,data_10kb,data_50kb,data_100kb,data_250kb,data_500kb,data_1mb,data_2mb,data_5mb,data_10mb,data_25mb,data_50mb,data_100mb,data_250mb,data_500mb,data_1gb,data_1900mb \
     --warmup=3 \
     --export-json output.json \
     "../zig-out/bin/simdjson minify < {input}.json" \
     "../zig-out/bin/simdjson --use-std-lib minify < {input}.json" # \

 uv run plot_line.py output.json --throughput --output minify.png

hyperfine \
    --warmup=3 \
    --export-json output.json \
    "../zig-out/bin/simdjson parse_twitter" \
    "../zig-out/bin/simdjson --use-std-lib parse_twitter" \

# 10,000 iterations of parsing this file
uv run plot_bar.py output.json --size "$(( $(stat -f%z twitter.json) * 10000 ))" --no-error-bars --output parse_twitter.png
