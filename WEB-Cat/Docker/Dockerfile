# Build tomcat image
FROM tomcat:9.0.11-jre8

#Environment variables
ENV DEBIAN_FRONTEND noninteractive

#Expose Port 80
EXPOSE 80
RUN sed -i 's/port="8080"/port="80"/' /usr/local/tomcat/conf/server.xml

#Install WEB-Cat
COPY config /
RUN rm -rf /usr/local/tomcat/webapps/ROOT; \
	wget https://sourceforge.net/projects/web-cat/files/latest/download -O /usr/local/tomcat/webapps/ROOT.war; \
	mkdir /usr/local/tomcat/webapps/ROOT;\
	cd /usr/local/tomcat/webapps/ && unzip -qq ROOT.war -d /usr/local/tomcat/webapps/ROOT; \
	mv /configuration.properties /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/
	
#Install perl
RUN apt-get update; apt-get install build-essential -y ; \
	curl -L http://xrl.us/installperlnix | bash; \
	/root/perl5/perlbrew/build/perl-5.28.0/perl-5.28.0/utils/cpan install URI::Escape; \
	cp -r /root/perl5/perlbrew/perls/perl-5.28.0/lib/site_perl/5.28.0/URI /usr/share/perl/5.24/
	
#Install java
RUN cd /usr/lib/jvm && wget --no-check-certificate -c --header "Cookie: oraclelicense=accept-securebackup-cookie" http://download.oracle.com/otn-pub/java/jdk/11+28/55eed80b163941c8885ad9298e6d786a/jdk-11_linux-x64_bin.tar.gz
RUN	cd /usr/lib/jvm && tar xfz jdk-11_linux-x64_bin.tar.gz
	
#Copy JavaTddPlugin and BatchPlugin
COPY JavaTddPlugin /plugins/
COPY BatchPlugin /plugins/
COPY BatchProcessor /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/

#Install postfix
RUN echo "postfix postfix/mailname string <Email>" | debconf-set-selections; \
	echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections; \
	apt-get upgrade; \
	apt-get -y install libsasl2-modules postfix; \
	rm /etc/postfix/main.cf
COPY postfix-stuff /etc/postfix/
RUN postmap /etc/postfix/sasl_passwd; \
	apt-get install -q -y syslog-ng

#Install leaderboard
COPY leaderboard /usr/local/tomcat/webapps/ROOT/WEB-INF/lib/

#Start services
CMD ["sh", "-c", "service syslog-ng start; \
     service postfix start; \
     catalina.sh start; \
     sleep 90; \
     chmod -R 750 /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/; \
     while [ ! -f /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/Core.framework/Resources/WCPageWithNavigation.wo/WCPageWithNavigation.html ]; do sleep 1; done; \
     mv /usr/local/tomcat/webapps/ROOT/WEB-INF/lib/WCPageWithNavigation.html /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/Core.framework/Resources/WCPageWithNavigation.wo/; \
     tail -F /var/log/mail.log"] 