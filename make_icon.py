from PIL import Image

src = Image.open("ocusage/assets/opencode.png").convert("RGBA")
src.save("assets_icon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("icon.ico saved")
