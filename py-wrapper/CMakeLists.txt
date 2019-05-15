SET(PYSCRIPT py-wrapper CACHE STRING "Name of python script to wrap")
ADD_EXECUTABLE(${PYSCRIPT} py-wrapper.c)
