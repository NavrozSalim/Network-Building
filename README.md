# Listing laptop network

One Windows 11 laptop is the master. Three Windows 10 laptops are the workers. The master keeps the task list and gives the next task to a laptop that is free. If all three are busy, the task stays **pending** until one of them is free.

Nothing else has to be installed. Windows 10 and Windows 11 already include Windows PowerShell.

| Laptop | Address | What to run |
|---|---|---|
| listing-master | 192.168.1.26 | `Setup-Master.bat` once, then `Start-Master.bat` |
| listing-worker-1 | 192.168.1.39 | `Start-Worker.bat` |
| listing-worker-2 | 192.168.1.40 | `Start-Worker.bat` |
| listing-worker-3 | 192.168.1.41 | `Start-Worker.bat` |

The master page can send an Excel file to a free worker. That worker runs the Etsy or Reverb bot named on the page.

## 1. Copy this folder

Copy the whole `Network Building` folder onto each laptop with a USB drive. The workers do not need Git. Keep the same `config.json` on every laptop.

On each worker, set sleep to **Never** while it is plugged in: **Settings → System → Power**. A sleeping laptop looks offline.

## 2. Master, one time

On `listing-master`, right-click `Setup-Master.bat` and choose **Run as administrator**. Approve the prompt. You only do this once. It lets the other laptops connect to this PC on port 8787.

## 3. Start the master

Double-click `Start-Master.bat` and leave the window open.

On this laptop, open a browser to:

http://localhost:8787

The page shows three workers as offline until their windows are open.

## 4. Start each worker

On each worker, double-click `Start-Worker.bat` and leave the window open.

The page should change that laptop from offline to **free**. The worker window prints its name and address. Closing the window makes that laptop offline.

## 5. Try a task

On the master page, click **Add a 20 second test task**. A free worker should change to **busy**, then back to **free**.

Click **Add 4 test tasks** while all three workers are running. Three tasks are picked up. The fourth stays **pending** until one laptop is free again.

## 6. Send an Excel file

On the master page, choose the bot:

| Bot | What it runs |
|---|---|
| Etsy - create listings | `Selimum Etsy Listing Automation\create_listing.py` |
| Reverb - create listings | `create_listing\create_listing.py` |
| Reverb - price and stock | `price_stock\update_price_stock.py` |
| Reverb - change SKU | `sku_replace\sku_replace.py` |

Choose the `.xlsx` file and click **Send to a free laptop**. Type a store code such as `GG` to run only that store. Leave the store blank to run every store in the file on one laptop.

The paths in `config.json` must exist on every worker. One laptop runs one file at a time. If all three are busy, the file stays pending.

## If the master address changes

These addresses come from the router and can change after a reboot. On the master, open PowerShell and run `ipconfig`. If the `192.168.1` address is no longer `192.168.1.26`, put the new address in `config.json` on **every** laptop:

```json
"masterIp": "192.168.1.26"
```

Then close the master and worker windows and start them again. From the master, `ping` each worker address to confirm they still answer.

## Files

| File | Where |
|---|---|
| `Setup-Master.bat` | Master, once, as administrator |
| `Start-Master.bat` | Master, leave open |
| `Start-Worker.bat` | Each worker, leave open |
| `Add-Task.bat` | Master, optional, adds one test task |
| `config.json` | Same copy on every laptop |
| `dashboard.html` | The page the master shows in the browser |

`Add-Task.ps1 -Kind command -Command "hostname"` runs that command on the next free worker. The page is the way to send an Excel file.

The shared token in `config.json` is `listing-network`. Change it if other people use this Wi-Fi, and copy the new `config.json` to every laptop.
