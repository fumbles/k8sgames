cd deploy

# 1. Register the catalog with OLM (openshift-marketplace namespace)
kubectl apply -f config/catalog/catalogsource.yaml

# 2. Scope OLM to the games namespace
kubectl apply -f config/catalog/operatorgroup.yaml

# 3. Subscribe — OLM installs the Deployment automatically
kubectl apply -f config/catalog/subscription.yaml

# 4. Service and Route (static, applied once)
kubectl apply -f config/catalog/service.yaml
kubectl apply -f config/catalog/route.yaml
