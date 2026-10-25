# BOX CLOCK

為 CrossFit 與功能性體能訓練設計的單頁間歇計時器。支援 AMRAP、EMOM、Tabata、For Time，沒有帳號、廣告、追蹤或訓練紀錄。

## 功能

- Web Worker 以單調時鐘校正經過時間，避免每秒遞減造成累積誤差。
- AMRAP、EMOM、Tabata、For Time 四種原生流程。
- 準備倒數、最後 3 秒、階段切換與完訓聲音提示。
- Screen Wake Lock API 讓支援的瀏覽器在計時中保持螢幕常亮。
- PWA 應用程式殼層離線快取，可安裝至主畫面。
- 行動裝置、橫向顯示、鍵盤操作與螢幕閱讀器狀態提示。

## 隱私

所有設定與計時都在瀏覽器中執行，不送出、不保存，也沒有第三方分析程式。

## 本機開發

```sh
python3 -m http.server 4173 --directory dist
```

瀏覽 `http://localhost:4173`。Service Worker、Wake Lock 與安裝提示需要 `localhost` 或 HTTPS。

## 建置與驗證

```sh
npm run build
npm run verify
```

建置輸出位於 `dist/`。建置只產生本機檔案；發布需另執行 `npm run deploy -- <Cloudflare Pages 專案名稱>`。

## 專案結構

- `src/`：頁面、樣式、互動、Web Worker 與計時核心。
- `public/`：PWA manifest、Service Worker 與圖示。
- `tests/`：計時狀態與邊界測試。
- `scripts/`：專案產生、建置、驗證與發布流程。
