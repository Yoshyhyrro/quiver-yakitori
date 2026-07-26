import os
import subprocess
from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext

class CMakeExtension(Extension):
    def __init__(self, name, sourcedir=""):
        super().__init__(name, sources=[])
        self.sourcedir = os.path.abspath(sourcedir)

class CMakeBuild(build_ext):
    def run(self):
        for ext in self.extensions:
            self.build_extension(ext)

    def build_extension(self, ext):
        build_temp = os.path.abspath(self.build_temp)
        os.makedirs(build_temp, exist_ok=True)
        
        cmake_args = [
            f"-DCMAKE_LIBRARY_OUTPUT_DIRECTORY={os.path.abspath('.')}",
            "-DCMAKE_BUILD_TYPE=Release"
        ]

        subprocess.check_call(["cmake", ext.sourcedir] + cmake_args, cwd=build_temp)
        subprocess.check_call(["cmake", "--build", "."], cwd=build_temp)

setup(
    name="quiver_system",
    version="0.1.0",
    author="Quiver Matrix Engine",
    description="C23 and Chicken Scheme hybrid engine for low-precision quantization",
    ext_modules=[CMakeExtension("quiver_bridge")],
    cmdclass={"build_ext": CMakeBuild},
    zip_safe=False,
)