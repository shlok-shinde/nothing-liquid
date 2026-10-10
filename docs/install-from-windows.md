# Installing Nothing Liquid next to Windows

For a computer that has only Windows on it. At the end, every time it starts you
pick Nothing Liquid or Windows; your Windows and its files stay as they are.

It takes about an hour: 15 minutes in Windows, 10 to install from a USB stick,
then 20 to 40 while Nothing Liquid sets up its desktop. You need:

- a USB stick of 4 GB or more (it gets erased)
- 60 GB of free space on the computer
- the computer plugged in, and internet (Wi-Fi is fine)

Back up anything you can't lose first. Nothing here should touch your files, but
changing disks is the one time it's worth having a copy.

## 1. In Windows

**Check Windows starts the modern way (UEFI).** Press Win+R, type `msinfo32`,
Enter. *BIOS Mode* should say **UEFI**. If it says *Legacy*, Nothing Liquid can't
go next to this Windows.

**Find your BitLocker key.** Most laptops encrypt the Windows disk (*Settings ›
Privacy & security › Device encryption*, or BitLocker). Changing how the computer
starts can make Windows ask for its recovery key once. Look it up at
[aka.ms/myrecoverykey](https://aka.ms/myrecoverykey) and write it down.

**Turn off Fast Startup.** *Control Panel › Power Options › Choose what the power
buttons do › Change settings that are currently unavailable*, untick **Turn on
fast startup**, Save. (With it on, Windows never fully shuts down, and leaves its
disk half open.)

**Make room.** Right-click Start › **Disk Management**. Right-click the **C:**
drive › **Shrink Volume**. In *Enter the amount of space to shrink*, type
`61440` (60 GB; more if you can spare it), then **Shrink**. A black bar,
*Unallocated*, appears: leave it like that. The installer finds it.

**Make the USB stick.** Download `nothing-liquid-….iso` from the
[releases page](https://github.com/shlok-shinde/nothing-liquid/releases). Write it
to the stick with [Rufus](https://rufus.ie) (pick the stick, *SELECT* the ISO,
*Partition scheme* **GPT**, *Target system* **UEFI**, START; if it asks, choose
**Write in DD Image mode**) or [balenaEtcher](https://etcher.balena.io).

## 2. Start from the USB stick

**Turn off Secure Boot.** The USB stick isn't signed by Microsoft, so with Secure
Boot on the computer refuses it. *Settings › System › Recovery › Advanced
startup* › **Restart now**, then *Troubleshoot › Advanced options › UEFI Firmware
Settings › Restart*. In the setup that opens, find **Secure Boot** (usually under
*Security* or *Boot*), set it to **Disabled**, save and exit (often F10).

Windows works without it. A few games with anti-cheat (Valorant, FACEIT) need it
on: switch it back on to play those, and off to start Nothing Liquid.

**Start the stick.** With the stick in, turn the computer on and press the boot
menu key straight away: often **F12**, F11, F9, F8 or Esc (Lenovo: F12 or the
Novo button; HP: F9; Dell: F12; ASUS: F8 or Esc; Acer: F12). Pick the USB stick
(the *UEFI:* one if it's listed twice).

## 3. The installer

It opens by itself. It asks:

1. **Your keyboard**, with a box to test it.
2. **Wi-Fi**, if there's no network cable.
3. **Where.** Pick **Next to Windows**: it uses the space you made, nothing else.
   *Erase this disk* deletes Windows: it asks you to type ERASE first.
4. **About you**: your name, a username and password (the one you'll log in
   with) and the computer's name. **Encrypt** is optional: then the password is
   asked every time the computer starts, and it's typed as on a US keyboard.
5. **Make it yours**: accent colour, font, the glass login screen, and whether
   the power button sleeps.

Then **Install**. About 10 minutes, mostly downloading. When it says
*INSTALLED*, take the stick out and **Restart now**.

## 4. The first start

A menu shows for 5 seconds: **Nothing Liquid** (it starts this if you do
nothing), **Nothing Liquid snapshots**, and **Windows Boot Manager**. Use the
arrow keys and Enter to start Windows.

The first time, Nothing Liquid opens a setup screen that installs the desktop:
press **Start**, type your password once, and wait 20 to 40 minutes (it builds
part of the desktop on your computer). Then **Restart now** and log in.

Some keys to start with: SUPER (the Windows key) opens search and your apps,
SUPER + Enter a terminal, SUPER + / every shortcut.

## If something goes wrong

- **It starts straight into Windows.** Some computers put Windows first again.
  Use the boot menu key and pick **Nothing Liquid**, or in the firmware setup
  move *Nothing Liquid* to the top of the boot order.
- **Windows asks for a BitLocker recovery key.** Type the key you wrote down;
  it asks once.
- **An update broke something.** Restart, pick **Nothing Liquid snapshots** in
  the menu, and pick one from before the update. Snapshots are taken before and
  after every update, plus one a day.
- **The setup screen stops with an error.** **Try again** usually works (it's
  mostly downloads). Its full log is in `~/.cache/nothing-liquid/logs`.

## Removing it

From Windows:

1. Open **Terminal (Admin)** and run `bcdedit /enum firmware`. Find the entry
   whose description is *Nothing Liquid*, and run
   `bcdedit /delete {its identifier}`.
2. In **Disk Management**, delete the *NothingLiquid* volume (and
   *NothingLiquidEFI*, if there is one), then right-click C: › **Extend Volume**
   to take the space back.
3. Optional: a 1 MB folder is left on Windows' EFI partition. In the admin
   terminal: `mountvol S: /S`, then `rmdir /s "S:\EFI\Nothing Liquid"`, then
   `mountvol S: /D`.
