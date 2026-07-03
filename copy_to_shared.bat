@echo off
echo [*] Dang copy toan bo thu muc d:\os sang D:\AlmaLinux\Shared\os ...

:: Su dung robocopy de copy nhanh ca thu muc (loai tru thu muc .git)
robocopy "%~dp0." "D:\AlmaLinux\Shared\os" /E /XD .git

:: errorlevel cua robocopy < 8 la dang chay tot (0-7 success)
if %ERRORLEVEL% LSS 8 (
    echo.
    echo [+] Da copy thanh cong sang D:\AlmaLinux\Shared\os nhe dai ca!
) else (
    echo.
    echo [!] Co loi xay ra trong qua trinh copy!
)

pause
