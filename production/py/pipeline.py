#!/usr/bin/env python3


import yaml, json, os, logging
from fcntl import flock, LOCK_EX, LOCK_NB
from typing import List
import pdb


logger = logging.getLogger("cnrs")
DEBUG  = logger.debug
INFO   = logger.info
WARN   = logger.warn
ERROR  = logger.error


class Pipeline:
    def __init__(self, stages_init, user_data, status_file, log_level, **kwargs):
        self.user_data = user_data
        self.status_file = status_file
        self.config = self.load_config()
        self.status = self.load_status()
        self.stages_cust = False
        self.stages = stages_init
        self.string_map = { s.name:i for i, s in enumerate(self.stages) }
        _ = kwargs

        print(self.string_map)
        assert self.config['global']['output_dir'], "without output directory configed"

        self.output_dir = self.config['global']['output_dir']
        os.makedirs(self.output_dir, exist_ok=True)
        self.log_init(log_level)

    def log_init(self, level=""):
        log_mapping = {"debug": logging.DEBUG, "info": logging.INFO, "warn": logging.WARN, "error": logging.ERROR}
        try:
            logLevel = log_mapping[level]
        except:
            logLevel = logging.INFO
        logger.setLevel(logLevel)

        # create a log handler, write the log to disk
        file_handler = logging.FileHandler(f'{self.output_dir}/debug.log')
        file_handler.setLevel(logLevel)

        # create a log handler which is used to output to console
        stream_handler = logging.StreamHandler()
        stream_handler.setLevel(logging.DEBUG) 

        # define the log handler output format
        fmt = '%(asctime)s.%(msecs)03d[%(filename)s:%(lineno)-3d][%(levelname)5s] %(message)s'
        formatter = logging.Formatter(fmt, "%H:%M:%S")
        file_handler.setFormatter(formatter)
        stream_handler.setFormatter(formatter)

        # add handlers to logger
        logger.addHandler(file_handler)
        logger.addHandler(stream_handler)

    def load_config(self):
        with open(self.user_data, 'r') as f:
            return yaml.safe_load(f)

    def load_status(self):
        try:
            if os.path.exists(self.status_file) :
                with open(self.status_file, 'r') as f:
                    return json.load(f)
            else:
                return {"current_stage": 0, "current_action": 0}
        except Exception as _:
            return {"current_stage": 0, "current_action": 0}

    def save_status(self):
        if self.stages_cust:
            return
        with open(self.status_file, 'w') as f:
            json.dump(self.status, f)

    def clear_file(self, file):
        with open(file, 'w') as _:
            INFO(f"clear {file}")
            pass

    def _start_stages(self, start):
        if not start:
            return
        if len(start) > 2:
            WARN(f"Too many parameter:{start[2:]}")

        start_stage = self.string_map[start[0]]
        start_action = [0]
        if len(start) >= 2:
            start_action = [i for i,action in enumerate(self.stages[0].actions) if action.__name__ == start[1]]
        self.status['current_stage'] = start_stage
        self.status['current_action'] = start_action[0]
        INFO(f"start with stage:{start_stage}, action:{start_action[0]}")

    def _sort_with_index(self, array: List, new_indices: List):
        m = len(array)
        n = len(new_indices)
        replication = 1 if len(set(new_indices)) < len(new_indices) else 0
        if n == 0 or replication:
            ERROR("Can not support replicated stages .")
            return

        pos_mapping = {i: new_indices[i] for i in range(len(new_indices))}
        new_indices.extend([0] * (m-n))
        DEBUG(pos_mapping)
        for i in range(n-1 if m == n else n):
            target = new_indices[i]
            DEBUG(f"--->i:{i}, target: {target}")
            j = i
            while target < i :
                target = pos_mapping[j]
                j = pos_mapping[j]
                DEBUG(f"\tNEW i:{i}, target: {target}")
            if target != i:
                array[i], array[target] = array[target], array[i]
            i += 1
        for i in range(n,m):
            array[i] = None


    def _input_stages(self, stages):
        if not stages:
            return
        self.stages_cust = True
        self.status = {"current_stage": 0, "current_action": 0}
        self.clear_file(self.status_file)

        new_indices = [self.string_map[s] for s in stages if stages]

        py_style = 0
        if py_style :
            new_stages = [self.stages[i] for i in new_indices]
            self.stages = new_stages
        else:
            self._sort_with_index(self.stages, new_indices)

    def run(self, start, stages, **kwargs):
        class SuspendException(Exception):
            pass

        self._start_stages(start)
        self._input_stages(stages)
        _ = kwargs
        print(self.stages)

        lock_file = open(f"{self.config['global']['output_dir']}/.installer.lock", "w")
        try:
            flock(lock_file, LOCK_EX | LOCK_NB)
        except IOError:
            INFO("Another installer is already running.")
            return

        try:
            for i, stage in enumerate(self.stages[self.status["current_stage"]:], start=self.status["current_stage"]):
                if not stage:
                    continue
                DEBUG(f"Executing stage: {stage.name}")
                for j, action in enumerate(stage.actions[self.status["current_action"]:], start=self.status["current_action"]):
                    DEBUG(f"  Executing action: {action.__name__}")
                    if not action(self.config):
                        self.save_status()
                        if (self.config['global']['rollback']['enabled'] and
                            hasattr(stage, 'rollback')):
                            stage.rollback(self.config)
                        raise Exception(f"Action {action.__name__} in stage {stage.name} failed")
                    self.status["current_action"] = j + 1
                if self.config['stages'][stage.name]['suspend']:
                    self.save_status()
                    raise SuspendException(f"Suspend in stage {stage.name}")
                self.status["current_stage"] = i + 1
                self.status["current_action"] = 0
                if self.config['global']['manual']['enabled'] :
                    INFO("checked manual mode")
                    self.save_status()
                    raise SuspendException(f"Suspend in stage {stage.name}")
            self.save_status()
            INFO("Installation completed successfully!")
        except SuspendException as e:
            INFO(f"Installation suspend at stage {e}")
        except Exception as e:
            INFO(f"Installation failed at stage {self.stages[self.status['current_stage']].name}, " f"action {self.stages[self.status['current_stage']].actions[self.status['current_action']].__name__}: {str(e)}")
        finally:
            lock_file.close()



