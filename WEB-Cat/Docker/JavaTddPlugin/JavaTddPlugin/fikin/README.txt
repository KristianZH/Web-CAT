Jars in this folder are used to support HTTP POST requests to
COMTOR from within ANT.  The following open-source jars should be placed
in this directory:

fikin-ant-1.7.4.jar
    http://sourceforge.net/projects/fikin-ant-tasks/files/fikin-ant-tasks/1.7.4%20release/fikin-ant-1.7.4.jar/download

commons-httpclient-3.1.jar
    http://archive.apache.org/dist/httpcomponents/commons-httpclient/binary/commons-httpclient-3.1.zip
    Note: newer versions of this jar are available, but 4.x is not
    compatible with fikin-ant tasks.

commons-logging-1.1.1.jar
    http://archive.apache.org/dist/commons/logging/binaries/commons-logging-1.1.1-bin.zip

The fikin-ant tasks also depend on commons-codec-1.6.jar, which is
located in defaultJars/, so it is not duplicated in this folder.
