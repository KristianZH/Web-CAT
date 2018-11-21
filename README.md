# webcat

## Prerequisites
1. navigate to Web-CAT/WEB-Cat/Docker/
2. open config/configuration.properties and set the following fields: 
	'dbConnectPasswordGLOBAL' , 'coreAdminEmail' , 'dbConnectUserGLOBAL' , 'AdminUsername'
3. open postfix-stuff/sasl_passwd and set marked mail:passwoed field
4. In Dockerfile set also the marked field 'Email' from the postfix instalation.
5. navigate to Web-CAT/kubernetes-yaml's/mysql/secrets.yaml and set the marked fields, with base64 encoding.

## Install WEB-Cat

1. git clone https://github.com/KristianZH/Web-CAT.git
2. navigate to WEB-CAT-Grader/kubernetes-yaml's/mysql
3. kubectl create -f storageclass.yaml (once per cluster)
4. kubectl create -f secrets.yaml (once per cluster)
5. kubectl create -f mysql-config.yaml
6. kubectl create -f mysql-services.yaml
7. kubectl create -f statefulset.yaml
8. navigate to Web-CAT/mysql-init
9. kubectl cp init.sql mysql-0:/
10. kubectl exec -it mysql-0 -- bash
11. mysql -u <-username-> -p<-password-> <-dbname-> < "init.sql"; exit; exit;
12. navigate to WEB-CAT-Grader/kubernetes-yaml's/Web-CAT
13. kubectl create -f data-pvc.yaml
14. kubectl create -f webcat-node.yaml
15. kubectl create -f service.yaml
16. copy webcat pod's name from : kubectl get po
17. kubectl exec -it <-pod's name-> -- bash
18. cp -r /plugins/BatchPlugin /usr/web-cat-storage/ (once per cluster)
19. cp -r /plugins/JavaTddPlugin /usr/web-cat-storage/UserScripts/FMI/stoyo/ (once per cluster)

## Push new WEB-Cat image

1. install docker
2. eval "$(docker-machine env <-docker-machine-name->)"
3. docker login -u <-dockerhubName-> -p <-dockerhubPassword->
4. navigate to WEB-CAT-Grader/WEB-Cat/Docker
5. docker build -t webcat:v2 .
6. docker tag webcat:v2 <-dockerhubName->/webcat:v<-container-version->
7. docker push <-dockerhubName->/webcat:v<-container-version->
8. kubectl set image deployments/webcat-node webcat-node=<-dockerhubName->/webcat:v<-container-version->

## Edit Leaderboard 

1. create jar file with name "leaderboard.jar"
2. paste it in Web-CAT/WEB-Cat/Docker/leaderboard/

## Restart webcat's volumes

1. kubectl scale deployments/webcat-node --replicas=1
2. kubectl exec -it to webcat's pod and delete '/usr/web-cat-storage/FMI/' and everything inside '/usr/web-cat-storage/_Repositories'
3. kubectl cp init.sql file in mysql-0
4. kubectl exec -it mysql-0 -- bash;
5. navigate to init.sql and run mysql -u <-username-> -p <-dbname-> < "init.sql"
6. kubectl scale deployments/webcat-node --replicas=3

## Uninstall

1. kubectl delete statefulset mysql
2. kubectl delete configmap,service,pvc -l app=mysql
3. kubectl delete secret database-secret-config
4. kubectl delete storageclass gp2
5. kubectl delete deploy webcat-node
6. kubectl delete service webcat-node
7. kubectl delete pvc webcat-pvc
