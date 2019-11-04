#############      jdk-provider       #############
FROM amd64/openjdk:13-jdk-oracle AS jdk-provider

#############         tomcat          #############
FROM tomcat:9.0.11-jre8

#Environment variables
ENV DEBIAN_FRONTEND noninteractive

#Expose Port 80
EXPOSE 80
RUN sed -i 's/port="8080"/port="80"/' /usr/local/tomcat/conf/server.xml

#Install WEB-Cat
COPY config /
RUN rm -rf /usr/local/tomcat/webapps/ROOT; \
	wget https://sourceforge.net/projects/web-cat/files/latest/download -q -O /usr/local/tomcat/webapps/ROOT.war; \
	mkdir /usr/local/tomcat/webapps/ROOT;\
	cd /usr/local/tomcat/webapps/ && unzip -qq ROOT.war -d /usr/local/tomcat/webapps/ROOT; \
	mv /configuration.properties /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/
	
#Install perl
RUN apt-get update; apt-get install build-essential -y ; \
	curl -L http://xrl.us/installperlnix | bash; \
	/root/perl5/perlbrew/build/perl-5.28.0/perl-5.28.0/utils/cpan install URI::Escape; \
	cp -r /root/perl5/perlbrew/perls/perl-5.28.0/lib/site_perl/5.28.0/URI /usr/share/perl/5.24/

#Install java
COPY --from=jdk-provider /usr/java/openjdk-13/ /usr/lib/jvm/openjdk-13/
	
#Copy JavaTddPlugin and BatchPlugin
COPY JavaTddPlugin /plugins/
COPY BatchPlugin /plugins/
COPY BatchProcessor /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/

#Install postfix
RUN echo "postfix postfix/mailname string ${HOSTNAME}.localdomain" | debconf-set-selections; \
	echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections; \
	apt-get upgrade; \
	apt-get -y install libsasl2-modules syslog-ng postfix; \
	rm /etc/postfix/main.cf
COPY postfix-stuff /etc/postfix/

#Start services
CMD ["sh", "-c", "service syslog-ng start; \
     echo [smtp.gmail.com]:587 ${POSTFIX_EMAIL}:${POSTFIX_PASSWORD} > /etc/postfix/sasl_passwd; \
     postmap /etc/postfix/sasl_passwd; \
     service postfix start; \
     catalina.sh start; \
     sleep 90; \
     chmod -R 750 /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/; \
     while [ ! -f /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/Core.framework/Resources/WCPageWithNavigation.wo/WCPageWithNavigation.html ]; do sleep 1; done; \
     cp -r /usr/local/tomcat/webapps/ROOT/WEB-INF/Web-CAT.woa/Contents/Library/Frameworks/. /usr/local/tomcat/webapps/ROOT/; \
     tail -F /var/log/mail.log"]
