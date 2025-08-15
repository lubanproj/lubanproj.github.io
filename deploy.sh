#!/bin/bash

set -e

# 1. 构建 Hugo 项目
hugo

# 2. 进入 public 目录
cd public

# 3. 初始化临时 Git 仓库
#git init
#git remote add origin https://github.com/lubanproj/lubanproj.github.io.git 

# 4. 提交到 gh-pages 分支
git checkout gh-pages
git add .
git commit -m "Deploy site $(date '+%Y-%m-%d %H:%M:%S')"
git push --force origin gh-pages

# 5. 返回上一级
cd ..
git checkout main


echo "✅ 部署完成"

