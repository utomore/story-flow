-- | 結構化輸出的 JSON Schema 建構。
--
-- llama.cpp 會把 @response_format.json_schema@ 編譯成 GBNF,所以 schema
-- 不只是驗證,而是**產生時的文法約束**:不在列舉裡的值模型根本吐不出來。
-- 這是本套件對抗「模型選錯分類」最有效的一道防線,遠強過在 prompt 裡
-- 請求模型守規矩。
--
-- == 屬性順序的注意事項
--
-- 讓模型先寫「判斷理由」再寫「答案」,可以逼它在承諾一個值之前先想過 ——
-- 而由於推理內容走的是另一個不受約束的通道,這是唯一可靠的帶內思考。
--
-- 但實際輸出的欄位順序取決於 llama.cpp 內部怎麼走訪 schema,而 aeson 的
-- 'Data.Aeson.object' 本身**不保證**序列化順序。因此這裡不倚賴順序被保留:
-- 理由欄位一律取名為 @analysis@,它在**字母序**與**宣告序**下都排在
-- @category@ 之前。兩種假設下都成立的作法,不需要先知道是哪一種。
module AssetDB.AI.Schema
  ( responseFormat
  , objectOf
  , stringOf
  , enumOf
  , arrayOf
  , numberOf
  ) where

import Data.Aeson
import Data.Aeson.Key qualified as K
import Data.Text (Text)

-- | 包成 llama.cpp 認得的 @response_format@。
responseFormat :: Text -> Value -> Value
responseFormat name schema =
  object
    [ "type" .= ("json_schema" :: Text)
    , "json_schema" .= object ["name" .= name, "schema" .= schema]
    ]

-- | 全部欄位皆為必填的物件。
--
-- 刻意不提供「選填欄位」:選填欄位讓模型可以靜靜地略過難的那一個,
-- 而略過的正好都是我們最想要的欄位。要它答不出來時,用列舉裡的
-- @unknown@ 表達,那是明示的,可以被統計、可以被過濾。
objectOf :: [(Text, Value)] -> Value
objectOf props =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object [K.fromText k .= v | (k, v) <- props]
    , "required" .= map fst props
    , "additionalProperties" .= False
    ]

stringOf :: Text -> Value
stringOf desc = object ["type" .= ("string" :: Text), "description" .= desc]

-- | 封閉列舉。這是整個模組存在的理由。
enumOf :: Text -> [Text] -> Value
enumOf desc vs =
  object
    [ "type" .= ("string" :: Text)
    , "description" .= desc
    , "enum" .= vs
    ]

-- | 有上限的陣列。上限是必要的:沒有它,模型會把同一個概念用五種說法
-- 各寫一遍,而每一個都會變成 tags 表裡的一列。
arrayOf :: Text -> Int -> Value -> Value
arrayOf desc maxItems item =
  object
    [ "type" .= ("array" :: Text)
    , "description" .= desc
    , "items" .= item
    , "maxItems" .= maxItems
    ]

-- | 數值。
--
-- 注意:GBNF 對 @minimum@ \/ @maximum@ 的約束並不可靠,所以呼叫端**必須**
-- 在解碼後自己夾範圍。不要把信心門檻建立在一個沒被驗證過的數字上。
numberOf :: Text -> Value
numberOf desc =
  object
    [ "type" .= ("number" :: Text)
    , "description" .= desc
    , "minimum" .= (0 :: Double)
    , "maximum" .= (1 :: Double)
    ]
