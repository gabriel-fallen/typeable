# Typeable Sites

## Site

https://typeable.io

Static files in `typeable.io` directory

## Blog

https://blog.typeable.io

Build blog in `blog.typeable.io` directory

```
stack build
stack exec blog rebuild
```

## Deploy

Deploy static sites with

```
./deploy.sh [target]
```

example:

```
./deploy.sh blog.typeable.io
```
