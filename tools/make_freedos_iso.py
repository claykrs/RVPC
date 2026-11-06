import pycdlib
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, vol_ident='FREEDOS13')
iso.add_file('media/freedos-boot.img', iso_path='/FREEDOS.IMG;1')
iso.add_eltorito('/FREEDOS.IMG;1', bootcatfile='/BOOT.CAT;1', media_name='floppy', boot_load_size=2880, boot_load_seg=0)
iso.write('media/freedos-boot.iso')
iso.close()
print('ok')
