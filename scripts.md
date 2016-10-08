Python pip behind proxy:

1. download or `pip3 install PySocks`

2. edit pip source file `init.py`:

```python
# edited by cc
need_socks5_proxy = input('need proxy? [y/n] default to YES')
if need_socks5_proxy != 'n':
    import socks
    import socket
    socks.set_default_proxy(socks.SOCKS5, "localhost")
    socket.socket = socks.socksocket
# end edit. added socks5 proxy support

```

or `--proxy <proxy>`



Homebrew behind proxy:

`ALL_PROXY=socks5://localhost:1080 brew install python3`

or

`proxy=http://username:password@host:port`:`.curlrc`


**homebrew** 
```
1. /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
2. brew update
3. brew doctor
4. brew install curl
5. brew link curl --force
6. brew install python3
```
**Xcode**
```
1. curl -fsSL https://raw.githubusercontent.com/supermarin/Alcatraz/deploy/Scripts/install.sh | sh
2. pip3 install scrapy
3. pip3 install requests
4. pip3 install beautifulsoup4
5. pip3 install aiohttp
6. pip3 install aiomysql
7. pip3 install jinja2
8. pip3 install flask
```
**Design**
```
1. https://www.lingoapp.com
2. pixave
```





