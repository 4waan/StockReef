import React from 'react';
import {Composition} from 'remotion';
import {Demo} from './Demo';
import {Pitch} from './Pitch';
import demoTimeline from './timeline-demo.json';
import pitchTimeline from './timeline-pitch.json';
import type {VideoProps} from './Video';

const size = {fps: 30, width: 1920, height: 1080};
const music: VideoProps = {guide: false, voices: {}};
const guide: VideoProps = {guide: true, voices: {}};

export const RemotionRoot: React.FC = () => (
	<>
		<Composition id="Pitch" component={Pitch} durationInFrames={pitchTimeline.total} {...size} defaultProps={music} />
		<Composition id="PitchGuide" component={Pitch} durationInFrames={pitchTimeline.total} {...size} defaultProps={guide} />
		<Composition id="Demo" component={Demo} durationInFrames={demoTimeline.total} {...size} defaultProps={music} />
		<Composition id="DemoGuide" component={Demo} durationInFrames={demoTimeline.total} {...size} defaultProps={guide} />
	</>
);
