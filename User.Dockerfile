FROM xdocker_x86_64/s390x
RUN groupadd users || /bin/true
RUN groupmod -g 985 users
RUN useradd -u 1000 -g 985 -G users -m -s /bin/bash jeanlego
CMD [ "/bin/bash" ]

