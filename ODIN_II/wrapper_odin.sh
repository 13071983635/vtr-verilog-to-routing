#!/bin/bash
trap ctrl_c INT SIGINT SIGTERM
SHELL=/bin/bash
QUIT=0

export TIME="\
	Elapsed Time:      %e Seconds
	CPU:               %P
	Max Memory:        %M KiB
	Average Memory:    %K KiB
	Minor PF:          %R
	Major PF:          %F
	Context Switch:    %c+%w
"

##############################################
# grab the input args
INPUT=$@

##############################################
# grab the absolute Paths
THIS_SCRIPT=$(readlink -f $0)
THIS_SCRIPT_EXEC=$(basename ${THIS_SCRIPT})
ODIN_ROOT_DIR=$(dirname ${THIS_SCRIPT})

EXEC="${ODIN_ROOT_DIR}/odin_II"
if [ ! -f ${EXEC} ]; then
	echo "Unable to find the odin executable at ${EXEC}"
	exit 120
fi

TIME_EXEC=$($SHELL -c "which time") 
VALGRIND_EXEC="valgrind --leak-check=full --max-stackframe=128000000 --error-exitcode=1"
PERF_EXEC="perf stat record -a -d -d -d -o"
GDB_EXEC="gdb --args"
LOG=""
LOG_FILE=""
TEST_NAME="odin"
FAILURE_FILE=""
EXIT_STATUS=3
TIME_LIMIT="86400s" #default to a full day
TOOL_SPECIFIED="off"
USE_TIMEOUT="on"
CANCEL_LOGS="off"
COLORIZE_OUTPUT="off"


function help() {
printf "
Called program with $[INPUT]

Usage: ./wrapper_odin.sh [options] CMD
			--tool [ gdb, valgrind, perf ]              * run with one of the specified tool and only one
			--log_file                                  * output status to a log file
			--test_name                                 * label the test for pretty print
			--failure_log                               * output the display label to a file if there was a failure
			--time_limit                                * stops Odin after X seconds
			--limit_ressource				            * limit ressource usage using ulimit -m (25% of hrdw memory) and nice value of 19
			--colorize                                  * colorize the output
"
}

function log_it {
	INPUT="$@"
	LOG="${LOG}${INPUT}"
}

function dump_log {
	#print to destination log if set
	if [ "_${LOG}" != "_" ]
	then
		if [ "_${LOG_FILE}" != "_" ]
		then
			echo "${LOG}" > ${LOG_FILE}
			echo "" > ${LOG_FILE}
		else
			echo "${LOG}"
			echo ""
		fi
		LOG=""
	fi

}

function ctrl_c() {
	trap '' INT SIGINT SIGTERM
	QUIT=1

	while [ "_${QUIT}" != "_0" ]
	do
		echo "** ODIN WRAPPER EXITED FORCEFULLY **"
		jobs -p | xargs kill &> /dev/null
		pkill odin_II &> /dev/null
		#should be dead by now
		exit 1
	done
}

#this hopefully will force to swap more
function restrict_ressource {
	#some benchmark will eat all your ressource and OOM. setting a limit prevents this from happening, 
	# LUPEEG64 can use up to 36 Gb of Memory in total, We recommend growing your swap space

	PERCENT_LIMIT_FOR_LOW_RESSOURCE=20
	NICE_VALUE=19

	MEMORY_SIZE=$(grep MemTotal /proc/meminfo |awk '{print $2}')
	MEMORY_SIZE=$(( $(( $(( ${MEMORY_SIZE} )) * ${PERCENT_LIMIT_FOR_LOW_RESSOURCE} )) / 100 ))

	ulimit -m ${MEMORY_SIZE}
	renice -n ${NICE_VALUE}  -p $$ &> /dev/null

	log_it "Setting Nice value to ${NICE_VALUE}\n"
	log_it "Virtual Memory Limit:\t$(ulimit -a | grep "virtual memory" | tr -s ' ' | cut -d ')' -f2)\n" 
	log_it "Physical Memory Limit:\t$(ulimit -a | grep "max memory size" | tr -s ' ' | cut -d ')' -f2)\n"
	dump_log
}

RED=""
NO_COLOR=""
if [[ ! -f /dev/stdout ]]
then
	RED="\033[0;31m"
	NO_COLOR="\033[0m"
fi

function pretty_print_status() {

	RESULT=$1
	line=$(printf '\040%.0s\056%.0s' {1..16})
	empty_line=$(printf '\040%.0s\040%.0s' {1..16})

	if [ "_$RESULT" == "_" ]
	then
		printf "  ${empty_line} ${TEST_NAME}\n"
	elif [ "_$RESULT" == "_Ok" ] || [ "_${COLORIZE_OUTPUT}" == "_off" ]
	then
		printf "  ${RESULT}${line:${#RESULT}} ${TEST_NAME}\n"
	else
		printf "  \033[0;31m${RESULT}${line:${#RESULT}}\033[0m ${TEST_NAME}\n"
	fi
}
function display() {
	# we display status to std out if there is a log file
	case $1 in
		running)			pretty_print_status "";;
		passed)				pretty_print_status "Ok";;
		*)
			case $1 in
				failed)		pretty_print_status "Failed";;
				timeout)	pretty_print_status "Timeout";;
				leak)
					if [ "$2" == "1" ]
					then
						pretty_print_status "[$2]Leak"
					else
						pretty_print_status "[$2]Leaks"
					fi
					;;
				*);;
			esac
			[ "_${FAILURE_FILE}" != "_" ] && echo "${TEST_NAME}" >> ${FAILURE_FILE}
		;;
	esac
}

#########################################################
#	START HERE

if [[ "$#" == 0 ]]
then
	help
	exit 0
fi

while [[ "$#" > 0 ]]
do 
	case $1 in
		--log_file)
			LOG_FILE=$2
			shift
			;;

		--test_name)
			TEST_NAME=$2
			shift
			;;

		--failure_log)
			FAILURE_FILE=$2
			shift
			;;
		
		--time_limit)
			TIME_LIMIT=$2
			shift
			;;

		--limit_ressource) 
			restrict_ressource 
			;;

		--colorize)
			COLORIZE_OUTPUT="on"
			;;

		--tool)
			USE_TIMEOUT="off"

			if [ ${TOOL_SPECIFIED} == "on" ]; then
				echo "can only run one tool at a time"
				help
				exit 99
			else
				case $2 in
					valgrind)
						EXEC="${VALGRIND_EXEC} ${EXEC}"
						;;
					gdb)
						CANCEL_LOGS="on"
						EXEC="${GDB_EXEC} ${EXEC}"
						;;
					perf)
						if [ "_$3" == "_" ]; then
							echo "You must pass an output file for perf to log"
							help
							exit 99
						else
							EXEC="${PERF_EXEC} $3 ${EXEC}"
							shift
						fi
						;;
					*)
						echo "Invalid tool $2 passed in"
						help
						exit 99
						;;
				esac
				TOOL_SPECIFIED="on"
				shift
			fi
			;;
		*) 
			break
			;;
	esac 
	shift 
done

ODIN_ARGS=$(echo $@)
EXEC="${EXEC} ${ODIN_ARGS}"
USE_TEMP_LOG="off"

log_it "Starting Odin with: ${ODIN_ARGS}"
dump_log

if [ "${CANCEL_LOGS}" == "off" ]
then
	if [ "_${LOG_FILE}" == "_" ]
	then
		LOG_FILE=$(mktemp)
		USE_TEMP_LOG="on"
	fi
	EXEC="${TIME_EXEC} --output=${LOG_FILE} --append ${EXEC}"
else
	EXEC="${TIME_EXEC} ${EXEC}"
fi

if [ "${USE_TIMEOUT}" == "on" ]
then
	EXEC="timeout ${TIME_LIMIT} ${EXEC}"
fi

display "running"
dump_log

if [ "${CANCEL_LOGS}" == "off" ]
then
	if [ ${USE_TEMP_LOG} == "on" ]
	then
		${EXEC} &2>1 | tee ${LOG_FILE}
	else
		${EXEC} &>> ${LOG_FILE}
	fi
else
	${EXEC}
fi

if [ "$?" == "0" ] 
then
	display "passed"
	EXIT_STATUS=0
else
	# check for valgrind leaks
	ERROR_COUNT=$(cat ${LOG_FILE} | grep "ERROR SUMMARY:" | awk '{print $4}')

	case $2 in
		''|*[!0-9]*) 
			display "failed"
		;;
		*)
			display "leak" "${ERROR_COUNT}"
		;;
	esac


	EXIT_STATUS=1
fi

if [ ${USE_TEMP_LOG} == "on" ]
then
	rm -f ${LOG_FILE}
fi

dump_log
exit ${EXIT_STATUS}
### end here