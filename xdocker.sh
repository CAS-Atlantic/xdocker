#!/bin/bash

set -xe

EXIT_CODE=0
HOST="$(uname -m)"

QEMU_ARCH=(
	"x86_64"
	"arm"
	"aarch64"
	"i386"
	"ppc64le"
	"s390x"
)

DOCKER_ARCH=(
	"amd64"
	"arm32v7"
	"arm64v8"
	"i386"
	"ppc64le"
	"s390x"
)

SHARE=""
TARGET_ARCH=""

MY_ARCH_INDEX=999
OWNER="xdocker_${HOST}"
MOUNT_TYPE="rshared"
MOUNT_CMD=""
YOUR_REPO=$(echo "${USER}" | awk '{print tolower($0)}')


BASE_TAG=""
USER_TAG=""
FINAL_TAG=""

CUSTOM_DOCKERFILE=""
CUSTOM_DOCKERFILE_DIR=""

# get the current user
U_UID=$(getent passwd ${USER} | cut -d ':' -f 3)
U_GID=$(getent passwd ${USER} | cut -d ':' -f 4)
U_GROUP=$(getent group  ${U_GID} | cut -d ':' -f 1)
U_SHELL=$(getent passwd ${USER} | cut -d ':' -f 7)



CURRENT_DIR=${PWD}
TEMP_DIR=$(mktemp -d)
BUILD_CONTEXT_DIR="${TEMP_DIR}/build/"
mkdir -p ${BUILD_CONTEXT_DIR}
echo "TEMP: ${TEMP_DIR}"
echo ""

_concat_path() {
	echo $1 | sed s+/++g
}

_help() {
printf "\
	
	Usage: 
	xdocker [OPTIONS] <target architecture> <shared directory> [ <...> docker run cmd are passed through ]
	
		OPTIONS:
			-f|--file <custom dockerfile>	gives a custom dockerfile to build from. 
				This script only supports running ubuntu, but the version is pulled from your docker file

		ARGS:
			\"target architecture\" 		is one of ${QEMU_ARCH[@]}
			\"shared directory\" 			is the directory to chroot into

"
}

_error_arg() {
	EXIT_CODE=1
	echo "ERROR_ARGS: $@"
	_help
	_exit
}

_error() {
	EXIT_CODE=2
	echo "ERROR: $@"
	_exit
}

_exit() {
	exit ${EXIT_CODE}
}

_parse_or_set_default() {
	if [ "_$1" != "_" ]; then
		echo $1 
	else 
		echo $2
	fi
}

_prep_path() {
	if [ "_$1" != "_" ]; then 
		temp_input=$(readlink -f $1 | sed 's/ /\\ /g')
		if [ -e "${temp_input}" ]; then
			echo "${temp_input}"
		fi
	else
		echo ""
	fi
}

_is_subdirectory_of() {
	case $1 in
		$2) echo 0;;
		$2/*) echo 1;;
		*) echo 0;;
	esac
}

_make_mount_cmd() {

	for dir_i in $@
	do
		skip_it=0
		for dir_j in $@
		do
			skip_it=$(_is_subdirectory_of $dir_i $dir_j)
			[ -z ${skip_it} ] || break
		done
		[ -z ${skip_it} ] && printf " "
	done
}

_get_arch_list() {
	docker search --format "{{.Name}}" ${DOCKER_ARCH[${MY_ARCH_INDEX}]} | grep ${DOCKER_ARCH[${MY_ARCH_INDEX}]}/ | cut -d '/' -f 2   
}

_get_arch_index() {
	# find index
	INDEX=0
	for arches in ${QEMU_ARCH[@]}
	do
		if [ "_$(echo ${QEMU_ARCH[$INDEX]} | grep $1)" != "_" ]; then
			echo "$INDEX"
			return 0
		fi
		INDEX=$(( INDEX+1 ))
	done

	echo "999"
	return 1
}

_clean_docker() {

	docker rm -v $(docker ps -a -q) &> /dev/null
	docker volume rm $(docker volume ls -q -f dangling=true) &> /dev/null
	docker rmi $(docker images -f dangling=true) &> /dev/null

	echo -e "\nContainers Left -----------\n"
	docker ps -a
	echo -e "\nVolumes Left -----------\n"
	docker volume ls
	echo -e "\nImages Left -----------\n"
	docker images
}

_get_docker_static_bin() {
	BIN_TEMP_DIR=$(mktemp -d)
	git clone https://github.com/multiarch/qemu-user-static.git ${BIN_TEMP_DIR}/
	docker build -t ${OWNER}/register -f ${BIN_TEMP_DIR}/qemu-user-static/register/Dockerfile ${BIN_TEMP_DIR}/qemu-user-static/register
	docker run --rm --privileged ${OWNER}/register --reset
}

_make_base_dockerfile() {

	COPY_QUEMU_INTRPRTR_DIRECTIVE=""
	case x86_64 in \
		${HOST}) 	COPY_QUEMU_INTRPRTR_DIRECTIVE="COPY qemu-${QEMU_ARCH[${MY_ARCH_INDEX}]}-static /usr/bin/";;
		*)			COPY_QUEMU_INTRPRTR_DIRECTIVE="";;
	esac

	FROM_DIRECTIVE=""
	CMD=""

	if [ "_${CUSTOM_DOCKERFILE}" != "_" ] && [ -f "${CUSTOM_DOCKERFILE}" ]
	then
        INPUT_FROM=$(cat ${CUSTOM_DOCKERFILE} | grep -e "[fF][rR][oO][mM]" | sed 's/[fF][rR][oO][mM]\s*//g')
		[ "_$(_get_arch_list | grep $(echo ${INPUT_FROM} | cut -d ':' -f 1))" != "_" ] || _error_arg "unsupported arch for custom dockerfile \"${INPUT_FROM}\""

        FROM_DIRECTIVE="FROM ${DOCKER_ARCH[${MY_ARCH_INDEX}]}/${INPUT_FROM}"
		CMD=""
    else
        FROM_DIRECTIVE="FROM ${DOCKER_ARCH[${MY_ARCH_INDEX}]}/ubuntu:18.04"
        CMD="CMD [ \"/bin/bash\" ]"
	fi

	echo -e "\
${FROM_DIRECTIVE}\n\
${COPY_QUEMU_INTRPRTR_DIRECTIVE}\n\
\n\
ENV DEBIAN_FRONTEND=noninteractive\n\
RUN apt-get update -q -q\n\
RUN apt-get install -y locales locales-all\n\
ENV LC_ALL en_US.UTF-8\n\
ENV LANG en_US.UTF-8\n\
ENV LANGUAGE en_US.UTF-8\n\
${CMD}\n\
" > ${TEMP_DIR}/Base.Dockerfile

	if [ "_${CUSTOM_DOCKERFILE}" != "_" ] && [ -f "${CUSTOM_DOCKERFILE}" ]
	then 
		sed 's/[fF][rR][oO][mM].*//g' ${CUSTOM_DOCKERFILE} >> ${TEMP_DIR}/Base.Dockerfile
		echo "" >> ${TEMP_DIR}/Base.Dockerfile
	fi
}

_build_base_dockerfile() {
	BASE_TAG="${OWNER}/${QEMU_ARCH[${MY_ARCH_INDEX}]}"
	docker build -t "${BASE_TAG}" -f ${TEMP_DIR}/Base.Dockerfile ${BUILD_CONTEXT_DIR}
}

_make_user_spec_dockerfile() {
	CMD="$(cat ${TEMP_DIR}/Base.Dockerfile | grep CMD)"
	echo -e "\
FROM ${BASE_TAG}\n\
RUN groupadd ${U_GROUP} || /bin/true\n\
RUN groupmod -g ${U_GID} ${U_GROUP}\n\
RUN useradd -u ${U_UID} -g ${U_GID} -G ${U_GROUP} -m -s /bin/bash ${USER}\n\
${CMD}\n\
" > ${TEMP_DIR}/User.Dockerfile
}

_build_user_spec_dockerfile() {
	USER_TAG="${BASE_TAG}_${YOUR_REPO}"
	docker build -t ${USER_TAG} -f ${TEMP_DIR}/User.Dockerfile ${BUILD_CONTEXT_DIR}
}

_make_dir_spec_dockerfile() {
	CMD="$(cat ${TEMP_DIR}/Base.Dockerfile | grep CMD)"
	echo -e "\
FROM ${USER_TAG}\n\
RUN mkdir -p ${SHARE}\n\
WORKDIR ${SHARE}\n\
${CMD}\n\
" > ${TEMP_DIR}/Dir.Dockerfile
}

_build_dir_spec_dockerfile() {
	SHARE_CONCAT=$(_concat_path ${SHARE})
	FINAL_TAG="${USER_TAG}_${SHARE_CONCAT}"
	docker build -t ${FINAL_TAG} -f ${TEMP_DIR}/Dir.Dockerfile ${BUILD_CONTEXT_DIR}
}

###########################################
# begin

#######################
# input args
DONE=""
while [ "_${DONE}" == "_" ]; do
	case $1 in
		-f|--file)
			if [ "_$2" != "_" ]; then
				CUSTOM_DOCKERFILE=$(readlink -f $2 | sed 's/ /\\ /g')
				if [ -e "${CUSTOM_DOCKERFILE}" ]; then
					CUSTOM_DOCKERFILE_DIR=$(dirname "${CUSTOM_DOCKERFILE}")
					echo "using a customized dockerfile: ${CUSTOM_DOCKERFILE}"
				else
					_error_arg "custom docker file is not valid: ${CUSTOM_DOCKERFILE}"
				fi
			else
				_error_arg "custom docker file is not passed in but flag is passed in"
			fi
			shift
			shift
		;;
		*)
			DONE="1"
		;;
	esac
done

TARGET_ARCH=""
if [ "_$1" == "_" ]; then
	_error_arg "target architecture is not passed in as argument"
else
	MY_ARCH_INDEX=$( _get_arch_index $1 )
	if [ "_${MY_ARCH_INDEX}" == "_999" ]; then
		_error_arg "target architecture $1 is not valid"
	else
		echo "using Arch ${QEMU_ARCH[${MY_ARCH_INDEX}]}"
		shift
	fi
fi

SHARE=""
if [ "_$1" == "_" ]; then
	_error_arg "Shared directory is not passed in as argument"
else
	if [ ! -d $1 ]; then
		_error_arg "Shared directory $1 does not exist"
	else
		SHARE=$(_prep_path $1)
		shift
	fi
fi


if [ "_${CUSTOM_DOCKERFILE_DIR}" != "_" ] && [ -d ${CUSTOM_DOCKERFILE_DIR} ]; then
	cp -r ${CUSTOM_DOCKERFILE_DIR}/* ./
	rm -f Dockerfile
fi

if [ ! -f /usr/bin/qemu-${QEMU_ARCH[${MY_ARCH_INDEX}]}-static ]; then
	_get_docker_static_bin
fi

cp /usr/bin/qemu-${QEMU_ARCH[${MY_ARCH_INDEX}]}-static ${TEMP_DIR}/build/

_make_base_dockerfile
_build_base_dockerfile

_make_user_spec_dockerfile
_build_user_spec_dockerfile

_make_dir_spec_dockerfile
_build_dir_spec_dockerfile

rm -Rf ${TEMP_DIR}

docker run -it \
	--privileged \
	--mount type=bind,source=${SHARE},target=${SHARE},bind-propagation=${MOUNT_TYPE} \
	--user ${USER} \
	"$@" \
	${FINAL_TAG}
