zig build docs
echo "Open http://localhost:8000/ to see docs"
python3 -m http.server -d zig-out/docs 8000
