  extern crate jwalk;
  use jwalk::WalkDir;
  use std::alloc::{alloc_zeroed, Layout};
  use std::ffi::{CStr, CString};
  use std::mem;
  use std::os::raw::c_char;
  
  #[no_mangle]
  pub unsafe extern "C" fn find_directory_count_given_name(
      dir_path: *const c_char,
      search_name: *const c_char,
  ) -> *const *const c_char {
      let dir_path = {
          assert!(!dir_path.is_null());
          CStr::from_ptr(dir_path)
      };
      let dir_path = dir_path.to_str().unwrap();
  
      let search_name = {
          assert!(!search_name.is_null());
          CStr::from_ptr(search_name)
      };
      let search_name = search_name.to_str().unwrap();
  
      let mut matching_paths: Vec<*const c_char> = vec![];
  
      for entry in WalkDir::new(dir_path).skip_hidden(false).into_iter() {
          let entry = entry.unwrap();
          if entry.file_name().to_string_lossy() == search_name && entry.file_type().is_dir() {
              let path = entry.path().to_string_lossy().into_owned();
              let path_cstr = CString::new(path).unwrap();
              matching_paths.push(path_cstr.into_raw());
          }
      }
  
      let paths_len = matching_paths.len();
      let data_layout = Layout::array::<*const c_char>(paths_len + 1).unwrap();
      let result = alloc_zeroed(data_layout) as *mut *const c_char;
      for (idx, &item) in matching_paths.iter().enumerate() {
          result.add(idx).write(item);
      }
      mem::forget(matching_paths);
      result.add(paths_len).write(std::ptr::null());
  
      result
  }  
