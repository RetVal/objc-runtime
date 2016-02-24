# objc-runtime
objc runtime 680

680 has an known bug, use 647 instead

at file objc-os.mm, function _objc_init, comment fixme.
Reason: _objc_init is called before global/static c++ instance constructor 
