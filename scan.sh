#!/bin/bash

OUTPUT_FILE="merged_scripts.txt"
SCRIPT_NAME=$(basename "$0")

# 清空输出文件（如果存在）
> "$OUTPUT_FILE"

find . -name "*.sh" -type f | sort | while IFS= read -r file; do
    filename=$(basename "$file")

    # 排除脚本自身
    if [ "$filename" != "$SCRIPT_NAME" ]; then
        {
            echo "- $file"
            echo '
```
'
            cat "$file"
            echo '
```
'
            echo
        } >> "$OUTPUT_FILE"
    fi
done

echo "完成！输出文件：$OUTPUT_FILE (已排除脚本自身: $SCRIPT_NAME)"