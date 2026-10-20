# 数据来源与许可

Healther 的代码采用 MIT 许可。随包分发的 `Sources/HealtherCore/Resources/foods.sqlite` 由以下公开数据集生成（`scripts/build_food_db.py`），各数据集保留其原始许可：

## 台湾食品营养成分资料库

- 提供方：卫生福利部食品药物管理署（TFDA）
- 来源：<https://data.gov.tw/dataset/8543>
- 许可：[政府资料开放授权条款第 1 版（Open Government Data License, version 1.0）](https://data.gov.tw/license)，可再利用、再分发，须注明出处。
- 处理：取热量、粗蛋白、粗脂肪、总碳水化合物、膳食纤维、糖、钠、饱和脂肪；名称与描述用 OpenCC 转换为简体中文。

> 本产品使用了卫生福利部食品药物管理署「食品营养成分资料库」开放数据。

## USDA FoodData Central

- 数据集：SR Legacy（2018-04）、Foundation Foods（2026-04）
- 来源：<https://fdc.nal.usda.gov/>
- 许可：公有领域（CC0 1.0）。引用：U.S. Department of Agriculture, Agricultural Research Service. FoodData Central.

## Open Food Facts（仅联网查询，不打包）

- 来源：<https://world.openfoodfacts.org/>
- 许可：数据库采用 [ODbL](https://opendatacommons.org/licenses/odbl/1-0/)，内容采用 Database Contents License。
- Healther 只在运行时按条码或名称查询，不在仓库中分发其数据。

## 未采用

- 《中国食物成分表》：没有许可清晰的开放电子版，因此未包含。之后可能提供“用户自行导入 CSV”的功能。
