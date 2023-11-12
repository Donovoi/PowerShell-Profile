import logging
import os
import subprocess
import sys
import win32com.client
import threading
import zipfile
from queue import Queue
import sys
import threading
from queue import Queue

def install_and_import(package):
    """
    Tries to import a package, and if it fails, installs it using pip and then imports it.
    """
    try:
        __import__(package)
    except ImportError:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", package])
    finally:
        globals()[package] = __import__(package)


install_and_import('pytsk3')
# install_and_import('pywin32')

# Setup basic logging
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')


class MyImgInfo(pytsk3.Img_Info):
    """
    Custom image information class that extends pytsk3.Img_Info.
    """

    def __init__(self, file_object):
        self.file_object = file_object
        super().__init__(self.file_object)


def add_to_zip(zipf, path, zip_path):
    """
    Add files to a zip archive
    """
    for root, _, files in os.walk(path):
        for file in files:
            zipf.write(os.path.join(root, file), os.path.relpath(
                os.path.join(root, file), zip_path))


def process_directory(directory, output_zip):
    """
    Process a directory and add it to a zip archive
    """
    try:
        with zipfile.ZipFile(output_zip, 'a', zipfile.ZIP_DEFLATED) as zipf:
            add_to_zip(zipf, directory, directory)
    except zipfile.BadZipFile as error:
        logging.error("Error processing directory %s: %s", directory, error)


def find_directories(filesystem, path, output_zip, queue):
    """
    Find directories to process and add to a queue
    """
    try:
        directory = filesystem.open_dir(path=path)
    except IOError as error:
        logging.error("IOError accessing path %s: %s", path, error)
        return

    for entry in directory:
        if entry.info.name.name in [".", ".."]:
            continue
        if entry.info.name.name.find("Microsoft.YourPhone") != -1:
            full_path = os.path.join(path, entry.info.name.name)
            queue.put(full_path)

        if entry.info.meta.type == pytsk3.TSK_FS_META_TYPE_DIR:
            sub_path = os.path.join(path, entry.info.name.name)
            find_directories(filesystem, sub_path, output_zip, queue)


def worker(output_zip, queue):
    """
    Worker function to process directories from a queue
    """
    while True:
        directory = queue.get()
        if directory is None:
            break
        process_directory(directory, output_zip)
        queue.task_done()
        
        



def list_physical_drives():
    wmi = win32com.client.GetObject("winmgmts:")
    for physical_disk in wmi.InstancesOf("Win32_DiskDrive"):
        print(f"ID: {physical_disk.DeviceID}, Model: {physical_disk.Model}, Size: {physical_disk.Size}")
        for partition in physical_disk.associators("Win32_DiskDriveToDiskPartition"):
            for logical_disk in partition.associators("Win32_LogicalDiskToPartition"):
                print(f"Drive: {logical_disk.DeviceID}, Size: {logical_disk.Size}")
                yield logical_disk.DeviceID





def main():
    """
    Main function to process Your Phone data
    """
    try:
        drives = list_physical_drives()
        # Open the image file
        print("Select the drive number of your phone from the list below:")
        for i, drive in enumerate(drives):
            print(f"{i}. {drive}")
        drive_number = int(input("Drive number: "))
        drive = list(drives)[drive_number]
        img = pytsk3.Img_Info(r"\\.\%s" % drive)
        # Attempt to auto-detect the file system
        filesystem = pytsk3.FS_Info(img)

        # ...

        try:
            # ...
        except Exception as e:
            logging.error(f"An unexpected error occurred: {e}")
            directory_queue = Queue()
        filesystem = None
        try:
            drives = list_physical_drives()
            # Open the image file
            print("Select the drive number of your phone from the list below:")
            for i, drive in enumerate(drives):
                print(f"{i}. {drive}")
            drive_number = int(input("Drive number: "))
            drive = list(drives)[drive_number]
            img = pytsk3.Img_Info(r"\\.\%s" % drive)
            # Attempt to auto-detect the file system
            filesystem = pytsk3.FS_Info(img)
            # Alternatively, you can try specifying the offset if auto-detection isn't working
            # filesystem = pytsk3.FS_Info(img, offset=<correct_offset>)
        except IOError as error:
            logging.error("Error opening file system: %s", error)
            sys.exit(1)

        directory_queue = Queue()
        threads = []
        num_worker_threads = 5  # Adjust this number based on your needs

        # Create worker threads
        for _ in range(num_worker_threads):
            t = threading.Thread(target=worker, args=(
                "YourPhoneData.zip", directory_queue,))
            t.start()
            threads.append(t)

        # Find directories and add them to the queue
        if filesystem:
            find_directories(filesystem, "/", "YourPhoneData.zip", directory_queue)
        # Create worker threads
        for _ in range(num_worker_threads):
            t = threading.Thread(target=worker, args=(
                "YourPhoneData.zip", directory_queue,))
            t.start()
            threads.append(t)

        # Find directories and add them to the queue
        find_directories(filesystem, "/", "YourPhoneData.zip", directory_queue)

        # Signal the worker threads to exit
        for _ in range(num_worker_threads):
            directory_queue.put(None)

        # Wait for all threads to complete
        for t in threads:
            t.join()

        logging.info(
            "Compression completed successfully. Check 'YourPhoneData.zip' for the output.")

    except Exception as e:
        logging.error(f"An unexpected error occurred: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
